require 'sinatra'

# 開発環境のみリローダーを有効にする
if ENV['RACK_ENV'] != 'production'
  require 'sinatra/reloader'
end

set :bind, '0.0.0.0'
set :port, ENV['PORT'] || 4567

require 'sinatra/cookies'
enable :sessions

# require 'pg'

# ======================
# データベース
# ======================
# db_url = ENV['DATABASE_URL']

# if db_url
#   # Renderなどのホスティング環境
#   client = PG.connect(db_url)
# else
#   # 開発環境
#   require 'dotenv'
#   Dotenv.load
  
#   client = PG.connect(
#     host: ENV['DB_HOST'] || 'localhost',
#     dbname: ENV['DB_NAME'] || 'whisky',
#     user: ENV['DB_USER'],
#     password: ENV['DB_PASSWORD']
#   )
# end

# app.rb
require 'pg'
require 'dotenv/load' if development? # 開発環境のみdotenvを使う

# Renderの環境変数 'DATABASE_URL' があればそれを使う
db_url = ENV['DATABASE_URL']

if db_url
  # 本番環境（Render）
  client = PG.connect(db_url)
else
  # ローカル開発環境（自分のPC）
  client = PG.connect(dbname: 'whisky', user: '...') # 自分の設定
end

get '/' do
  redirect '/top'  # views/top.erb を表示する場合
end

# ======================
# アカウント作成
# ======================
get '/makeAccount' do
  return erb :makeAccount
end

post '/makeAccount' do
  name = params[:name]
  password = params[:password]

  # 空欄チェック
  if name.to_s.strip.empty? || password.to_s.strip.empty?
    redirect '/makeAccount'
    return
  end

  # 「名前」と「パスワード」の両方が一致するデータがあるかチェック
  user_exists = client.exec_params(
    'SELECT * FROM users WHERE name = $1 AND password = $2',
    [name, password]
  )

  # すでに同じ組み合わせが存在すれば、作成画面へ戻す
  if user_exists.ntuples > 0
    session[:error] = 'このユーザー名とパスワードの組み合わせはすでに存在します'
    redirect '/makeAccount'
    return
  end

  # 存在しない場合のみ保存処理を実行
  client.exec_params(
    'INSERT INTO users (name, password) VALUES ($1, $2)',
    [name, password]
  )

  redirect '/top'
end

# ======================
# ログイン
# ======================
get '/login' do
  return erb :login
end

post '/login' do
  name = params[:name]
  password = params[:password]

  user = client.exec_params(
    'SELECT * FROM users WHERE name = $1 AND password = $2 LIMIT 1',
    [name, password]
  ).to_a.first

  # アカウントが存在しない場合にアラートを表示してログイン画面に戻す
  if user.nil?
    session[:error] = 'アカウントが存在しません'
    return erb :login
  end

  session[:user] = user
  redirect '/top'
end

# ======================
# ログアウト
# ======================
delete '/logout' do
  session[:user] = nil
  redirect '/login'
end

# ======================
# トップ
# ======================
get '/top' do
  # ログインしていない場合はログイン画面にリダイレクト
  if session[:user].nil?
    session[:error] = 'ログインしてください'
    return redirect '/login'
  end

  # DBからランダムに6件取得
  @random_posts = client.exec_params(
    'SELECT * FROM posts ORDER BY RANDOM() LIMIT 6'
  )

  return erb :top
end

# ======================
# 投稿
# ======================
get '/post' do
  # ログインしていない場合はログイン画面にリダイレクト
  if session[:user].nil?
    session[:error] = 'ログインしてください'
    return redirect '/login'
  end

  return erb :post
end

post '/post' do
  # ログインしていない場合はログイン画面にリダイレクト
  if session[:user].nil?
    session[:error] = 'ログインしてください'
    return redirect '/login'
  end


  # 画像の保存
  if !params[:img].nil? # データがあれば処理を続行する
    tempfile = params[:img][:tempfile] # ファイルがアップロードされた場所

    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    filename = "#{timestamp}_#{params[:img][:filename]}"
    save_to = "./public/images/#{filename}"

    FileUtils.mv(tempfile, save_to)

    @img_name = params[:img][:filename]
  end


  # データベースへ保存
  client.exec_params(
    'INSERT INTO posts (whisky_name, age, type, situation, aroma, taste, finish, balance, comment, img_url) 
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)',
    [
      params[:whisky_name],
      params[:age],
      params[:type],
      params[:situation],
      params[:aroma],
      params[:taste],
      params[:finish],
      params[:balance],
      params[:comment],
      filename
    ]
  )

  redirect '/reviews'
end

# 1. 候補検索：名前と年代をセットで返す
get '/api/whiskies' do
  content_type :json
  query = params[:q] || ''
  return { suggestions: [] }.to_json if query.empty?

  # 名前か年代のいずれかにヒットするように検索
  results = client.exec_params(
    "SELECT whisky_name, age FROM whiskies 
     WHERE whisky_name ILIKE $1 OR age ILIKE $1 LIMIT 10",
    ["%#{query}%"]
  )

  # 「商品名 年代」の形式で配列を作成
  suggestions = results.map { |row| "#{row['whisky_name']} #{row['age']}".strip }
  { suggestions: suggestions }.to_json
end

# 2. 詳細取得：送られてきた「商品名 年代」を分解してDB検索
get '/api/whisky_details' do
  content_type :json
  full_query = params[:q] || ''
  
  # スペースで分割（最後が年代であると仮定）
  parts = full_query.split(/\s+/)
  name_part = parts[0...-1].join(' ') # 年代以外
  age_part = parts.last               # 年代

  # DBから一致する行を取得
  result = client.exec_params(
    'SELECT whisky_name, age, type FROM whiskies WHERE whisky_name = $1 AND age = $2 LIMIT 1',
    [name_part, age_part]
  )

  # もし上記でヒットしなかった場合（年代がない入力など）の予備検索
  if result.ntuples == 0
    result = client.exec_params(
      'SELECT whisky_name, age, type FROM whiskies WHERE whisky_name = $1 LIMIT 1',
      [full_query]
    )
  end

  if result.ntuples > 0
    row = result[0]
    { found: true, name: row['whisky_name'], age: row['age'], type: row['type'] }.to_json
  else
    { found: false }.to_json
  end
end

# ======================
# 閲覧
# ======================
# 1. 年代を動的に取得するためのAPIを追加
get '/api/whisky_ages' do
  content_type :json
  name = params[:name] || ''
  return { ages: [] }.to_json if name.empty?

  # 指定された商品名に紐づく年代を重複なく取得
  results = client.exec_params(
    'SELECT DISTINCT age FROM whiskies WHERE whisky_name = $1 AND age IS NOT NULL ORDER BY age',
    [name]
  )

  ages = results.map { |row| row['age'] }
  { ages: ages }.to_json
end

# app.rb

get '/reviews' do
  if session[:user].nil?
    session[:error] = 'ログインしてください'
    return redirect '/login'
  end

  # 基本となるクエリ
  sql = 'SELECT * FROM posts WHERE 1=1'
  params_list = []

  # 1. 商品名 (部分一致)
  if params[:whisky_name] && !params[:whisky_name].empty?
    params_list << "%#{params[:whisky_name]}%"
    sql += " AND whisky_name ILIKE $#{params_list.size}"
  end

  # 2. 年代 (完全一致)
  if params[:age] && !params[:age].empty?
    params_list << params[:age]
    sql += " AND age = $#{params_list.size}"
  end

  # 3. タイプ (完全一致)
  if params[:type] && !params[:type].empty?
    params_list << params[:type]
    sql += " AND type = $#{params_list.size}"
  end

  # 4. 状況 (完全一致)
  if params[:situation] && !params[:situation].empty?
    params_list << params[:situation]
    sql += " AND situation = $#{params_list.size}"
  end

  sql += ' ORDER BY id DESC'

  @posts = client.exec_params(sql, params_list)

  return erb :reviews
end

# ======================
# API: ウイスキー候補検索
# ======================
# ウイスキー名候補検索（商品名のみを重複なく取得）
# app.rb の get '/api/whiskies' セクションを以下に差し替え

get '/api/whiskies' do
  content_type :json
  query = params[:q] || ''
  mode = params[:mode] # 'post' か 'review' を受け取る
  return { suggestions: [] }.to_json if query.to_s.strip.empty?

  if mode == 'post'
    # 投稿用：商品名と年代をセットで取得（重複を許容して具体的なボトルを選ばせる）
    results = client.exec_params(
      'SELECT whisky_name, age FROM whiskies WHERE whisky_name ILIKE $1 LIMIT 10',
      ["%#{query}%"]
    )
    suggestions = results.map { |row| "#{row['whisky_name']} #{row['age']}" }
  else
    # 絞り込み用（デフォルト）：商品名のみを重複なく取得
    results = client.exec_params(
      'SELECT DISTINCT whisky_name FROM whiskies WHERE whisky_name ILIKE $1 ORDER BY whisky_name LIMIT 10',
      ["%#{query}%"]
    )
    suggestions = results.map { |row| row['whisky_name'] }
  end

  { suggestions: suggestions }.to_json
end
