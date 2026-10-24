require 'sinatra/base'
require 'pg'
require 'json'
require 'bcrypt'
require 'securerandom'
require 'fileutils'
require 'connection_pool'

DB_URL     = ENV.fetch('DATABASE_URL', 'postgres://localhost/messenger')
UPLOAD_DIR = File.expand_path(ENV.fetch('UPLOAD_DIR', 'uploads'), __dir__)
MAX_UPLOAD = 25 * 1024 * 1024 # 25 MB
INLINE_IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

FileUtils.mkdir_p(UPLOAD_DIR)
POOL = ConnectionPool.new(size: 5, timeout: 5) { PG.connect(DB_URL) }

MSG_SELECT = <<~'SQL'
  SELECT m.id, m.sender_id, u.username AS sender, m.recipient_id, m.body,
         m.file_name, m.file_key, m.content_type, m.file_size,
         to_char(m.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at
  FROM messages m JOIN users u ON u.id = m.sender_id
SQL

class App < Sinatra::Base
  set :public_folder, File.join(__dir__, 'public')
  set :bind, '0.0.0.0'
  # Allow access via LAN IP / hostname (Sinatra 4.1+ blocks unknown hosts in development)
  set :host_authorization, { permitted_hosts: [] }

  helpers do
    def db(&blk)
      POOL.with(&blk)
    end

    def json(data, code = 200)
      status code
      content_type :json
      data.to_json
    end

    def body_json
      data = JSON.parse(request.body.read)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def current_user
      token = request.cookies['token']
      return nil if token.nil? || token.empty?
      db do |c|
        c.exec_params(
          'SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = $1',
          [token]
        ).first
      end
    end

    def require_user
      current_user || halt(json({ error: 'Not logged in' }, 401))
    end

    def start_session(user_id)
      token = SecureRandom.hex(32)
      db { |c| c.exec_params('INSERT INTO sessions (token, user_id) VALUES ($1, $2)', [token, user_id]) }
      response.set_cookie('token', value: token, path: '/', httponly: true,
                                   same_site: :lax, max_age: 60 * 60 * 24 * 30)
    end

    def format_message(r)
      msg = {
        id: r['id'].to_i,
        sender_id: r['sender_id'].to_i,
        sender: r['sender'],
        recipient_id: r['recipient_id']&.to_i,
        body: r['body'],
        created_at: r['created_at']
      }
      if r['file_key']
        msg[:file] = {
          name: r['file_name'],
          size: r['file_size'].to_i,
          url: "/files/#{r['id']}",
          image: INLINE_IMAGE_TYPES.include?(r['content_type'])
        }
      end
      msg
    end
  end

  get '/' do
    send_file File.join(settings.public_folder, 'index.html')
  end

  # ---------- Auth ----------

  post '/api/register' do
    d = body_json
    name = d['username'].to_s.strip
    pw = d['password'].to_s
    halt json({ error: 'Username must be 3-20 letters, numbers or underscores' }, 422) unless name.match?(/\A[A-Za-z0-9_]{3,20}\z/)
    halt json({ error: 'Password must be at least 6 characters' }, 422) if pw.length < 6

    begin
      row = db do |c|
        c.exec_params('INSERT INTO users (username, password_digest) VALUES ($1, $2) RETURNING id',
                      [name, BCrypt::Password.create(pw)]).first
      end
    rescue PG::UniqueViolation
      halt json({ error: 'That username is taken' }, 409)
    end
    start_session(row['id'])
    json({ id: row['id'].to_i, username: name })
  end

  post '/api/login' do
    d = body_json
    user = db do |c|
      c.exec_params('SELECT id, username, password_digest FROM users WHERE username = $1',
                    [d['username'].to_s.strip]).first
    end
    ok = user && BCrypt::Password.new(user['password_digest']) == d['password'].to_s
    halt json({ error: 'Wrong username or password' }, 401) unless ok
    start_session(user['id'])
    json({ id: user['id'].to_i, username: user['username'] })
  end

  post '/api/logout' do
    token = request.cookies['token']
    db { |c| c.exec_params('DELETE FROM sessions WHERE token = $1', [token]) } if token
    response.delete_cookie('token', path: '/')
    json({ ok: true })
  end

  get '/api/me' do
    me = require_user
    json({ id: me['id'].to_i, username: me['username'] })
  end

  get '/api/users' do
    me = require_user
    rows = db { |c| c.exec_params('SELECT id, username FROM users WHERE id <> $1 ORDER BY username', [me['id']]).to_a }
    json(rows.map { |r| { id: r['id'].to_i, username: r['username'] } })
  end

  # ---------- Messages ----------

  get '/api/messages' do
    me = require_user
    after = params['after'].to_i
    peer = params['with'].to_s

    if peer.empty? || peer == 'all'
      where = 'm.recipient_id IS NULL'
      args = [after]
    else
      where = '((m.sender_id = $2 AND m.recipient_id = $3) OR (m.sender_id = $3 AND m.recipient_id = $2))'
      args = [after, me['id'].to_i, peer.to_i]
    end

    sql = "SELECT * FROM (#{MSG_SELECT} WHERE m.id > $1 AND #{where} ORDER BY m.id DESC LIMIT 200) t ORDER BY t.id ASC"
    rows = db { |c| c.exec_params(sql, args).to_a }
    json(rows.map { |r| format_message(r) })
  end

  post '/api/messages' do
    me = require_user
    text = params['body'].to_s.strip
    halt json({ error: 'Message too long (max 5000 characters)' }, 422) if text.length > 5000

    rid = params['recipient_id'].to_s.empty? ? nil : params['recipient_id'].to_i
    if rid
      exists = db { |c| c.exec_params('SELECT 1 FROM users WHERE id = $1', [rid]).ntuples > 0 }
      halt json({ error: 'Recipient not found' }, 404) unless exists
    end

    name = key = ctype = size = nil
    file = params['file']
    if file.is_a?(Hash) && file[:tempfile]
      size = file[:tempfile].size
      halt json({ error: 'File too large (max 25 MB)' }, 413) if size > MAX_UPLOAD
      name = File.basename(file[:filename].to_s).gsub(/[^\w.\- ]/, '_')[0, 120]
      name = 'file' if name.empty?
      ext = File.extname(name)[0, 10].gsub(/[^\w.]/, '')
      key = SecureRandom.hex(16) + ext
      FileUtils.cp(file[:tempfile].path, File.join(UPLOAD_DIR, key))
      ctype = file[:type].to_s[0, 100]
    end

    halt json({ error: 'Write a message or attach a file' }, 422) if text.empty? && key.nil?

    id = db do |c|
      c.exec_params(
        'INSERT INTO messages (sender_id, recipient_id, body, file_name, file_key, content_type, file_size)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id',
        [me['id'].to_i, rid, text, name, key, ctype, size]
      ).first['id']
    end
    row = db { |c| c.exec_params("#{MSG_SELECT} WHERE m.id = $1", [id]).first }
    json(format_message(row), 201)
  end

  # ---------- File downloads (login + permission required) ----------

  get '/files/:id' do
    me = require_user
    m = db do |c|
      c.exec_params('SELECT * FROM messages WHERE id = $1 AND file_key IS NOT NULL', [params[:id].to_i]).first
    end
    halt 404 unless m

    allowed = m['recipient_id'].nil? || [m['sender_id'].to_i, m['recipient_id'].to_i].include?(me['id'].to_i)
    halt 403 unless allowed

    path = File.join(UPLOAD_DIR, File.basename(m['file_key']))
    halt 404 unless File.file?(path)

    inline = INLINE_IMAGE_TYPES.include?(m['content_type'])
    headers 'X-Content-Type-Options' => 'nosniff'
    send_file path,
              type: inline ? m['content_type'] : 'application/octet-stream',
              filename: m['file_name'],
              disposition: inline ? 'inline' : 'attachment'
  end
end
