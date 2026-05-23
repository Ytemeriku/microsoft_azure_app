from flask import Flask, jsonify, request
from flask import send_file
from flask_cors import CORS
import psycopg2
import os
import time
from dotenv import load_dotenv
from azure.storage.blob import BlobServiceClient, ContentSettings
from datetime import datetime
from io import BytesIO
from werkzeug.security import generate_password_hash

load_dotenv()

app = Flask(__name__)
CORS(app)


@app.after_request
def set_security_headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    return response

def get_db_connection():
    database_url = os.getenv('DATABASE_URL')

    if not database_url:
        raise RuntimeError('DATABASE_URL is not configured')

    return psycopg2.connect(database_url)


def connect_with_retry(retries=8, delay_seconds=2):
    last_error = None

    for attempt in range(retries):
        try:
            return get_db_connection()
        except Exception as exc:
            last_error = exc
            if attempt < retries - 1:
                time.sleep(delay_seconds)

    raise last_error

def init_db():
    try:
        conn = connect_with_retry()
        cur = conn.cursor()
        cur.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                surname VARCHAR(100) NOT NULL,
                password_hash VARCHAR(255) NOT NULL,
                creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        cur.execute('''
            ALTER TABLE users
            ADD COLUMN IF NOT EXISTS password_hash VARCHAR(255)
        ''')
        cur.execute('''
            UPDATE users
            SET password_hash = 'migrated_legacy_user'
            WHERE password_hash IS NULL
        ''')
        cur.execute('''
            ALTER TABLE users
            ALTER COLUMN password_hash SET NOT NULL
        ''')
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        print(f"DB init error: {e}")

init_db()

@app.route('/api/hello')
def hello():
    return jsonify({
        'message': 'Hello World from Backend!',
        'status': 'success'
    })

@app.route('/api/health')
def health():
    return jsonify({'status': 'healthy'})

@app.route('/api/db/users', methods=['GET'])
def get_users():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('SELECT id, name, surname, creation_date FROM users ORDER BY creation_date DESC')
        users = [{'id': row[0], 'name': row[1], 'surname': row[2], 'creation_date': str(row[3])} for row in cur.fetchall()]
        cur.close()
        conn.close()
        return jsonify({'users': users, 'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500


@app.route('/api/db/users/<int:user_id>', methods=['GET'])
def get_user_by_id(user_id):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('SELECT id, name, surname, creation_date FROM users WHERE id = %s', (user_id,))
        row = cur.fetchone()
        cur.close()
        conn.close()

        if not row:
            return jsonify({'error': 'User not found', 'status': 'error'}), 404

        user = {'id': row[0], 'name': row[1], 'surname': row[2], 'creation_date': str(row[3])}
        return jsonify({'user': user, 'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/db/users', methods=['POST'])
def add_user():
    try:
        data = request.get_json(silent=True) or {}
        name = data.get('name', '')
        surname = data.get('surname', '')
        password = data.get('password', '')
        
        if not name or not surname or not password:
            return jsonify({'error': 'Name, surname and password are required', 'status': 'error'}), 400

        if len(password) < 8:
            return jsonify({'error': 'Password must have at least 8 characters', 'status': 'error'}), 400

        password_hash = generate_password_hash(password)
            
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            'INSERT INTO users (name, surname, password_hash) VALUES (%s, %s, %s) RETURNING id, creation_date',
            (name, surname, password_hash)
        )
        result = cur.fetchone()
        user_id = result[0]
        creation_date = result[1]
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({'id': user_id, 'name': name, 'surname': surname, 'creation_date': str(creation_date), 'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500


@app.route('/api/db/users/<int:user_id>', methods=['PUT'])
def update_user(user_id):
    try:
        data = request.get_json(silent=True) or {}
        name = data.get('name')
        surname = data.get('surname')
        password = data.get('password')

        if not name and not surname and not password:
            return jsonify({'error': 'At least one field (name, surname, password) is required', 'status': 'error'}), 400

        updates = []
        values = []

        if name:
            updates.append('name = %s')
            values.append(name)

        if surname:
            updates.append('surname = %s')
            values.append(surname)

        if password:
            if len(password) < 8:
                return jsonify({'error': 'Password must have at least 8 characters', 'status': 'error'}), 400
            updates.append('password_hash = %s')
            values.append(generate_password_hash(password))

        values.append(user_id)

        conn = get_db_connection()
        cur = conn.cursor()
        query = f"UPDATE users SET {', '.join(updates)} WHERE id = %s RETURNING id, name, surname, creation_date"
        cur.execute(query, tuple(values))
        updated_row = cur.fetchone()

        if not updated_row:
            cur.close()
            conn.close()
            return jsonify({'error': 'User not found', 'status': 'error'}), 404

        conn.commit()
        cur.close()
        conn.close()

        return jsonify({
            'user': {
                'id': updated_row[0],
                'name': updated_row[1],
                'surname': updated_row[2],
                'creation_date': str(updated_row[3])
            },
            'status': 'success'
        })
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500


@app.route('/api/db/users/<int:user_id>', methods=['DELETE'])
def delete_user(user_id):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('DELETE FROM users WHERE id = %s RETURNING id', (user_id,))
        deleted_row = cur.fetchone()

        if not deleted_row:
            cur.close()
            conn.close()
            return jsonify({'error': 'User not found', 'status': 'error'}), 404

        conn.commit()
        cur.close()
        conn.close()
        return jsonify({'status': 'success', 'message': f'User {user_id} deleted'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/blob/upload', methods=['POST'])
def upload_blob():
    try:
        if 'file' not in request.files:
            return jsonify({'error': 'No file provided', 'status': 'error'}), 400
            
        file = request.files['file']
        if file.filename == '':
            return jsonify({'error': 'No file selected', 'status': 'error'}), 400
            
        if not file.filename.lower().endswith('.pdf'):
            return jsonify({'error': 'Only PDF files are allowed', 'status': 'error'}), 400
        
        blob_service_client = BlobServiceClient.from_connection_string(os.getenv('AZURE_STORAGE_CONNECTION_STRING'))
        container_name = os.getenv('AZURE_STORAGE_CONTAINER', 'uploads')
        
        # Generuj unikalną nazwę pliku
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f"pdf_{timestamp}_{file.filename}"
        
        blob_client = blob_service_client.get_blob_client(container=container_name, blob=filename)
        content_settings = ContentSettings(content_type='application/pdf')
        blob_client.upload_blob(file.read(), overwrite=True, content_settings=content_settings)
        
        return jsonify({'filename': filename, 'status': 'success', 'url': blob_client.url})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/blob/list', methods=['GET'])
def list_blobs():
    try:
        blob_service_client = BlobServiceClient.from_connection_string(os.getenv('AZURE_STORAGE_CONNECTION_STRING'))
        container_name = os.getenv('AZURE_STORAGE_CONTAINER', 'uploads')
        container_client = blob_service_client.get_container_client(container_name)
        
        blobs = [{'name': blob.name, 'size': blob.size, 'last_modified': str(blob.last_modified)} 
                 for blob in container_client.list_blobs()]
        
        return jsonify({'blobs': blobs, 'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/blob/download/<path:blob_name>', methods=['GET'])
def download_blob(blob_name):
    try:
        blob_service_client = BlobServiceClient.from_connection_string(os.getenv('AZURE_STORAGE_CONNECTION_STRING'))
        container_name = os.getenv('AZURE_STORAGE_CONTAINER', 'uploads')
        blob_client = blob_service_client.get_blob_client(container=container_name, blob=blob_name)

        download_stream = blob_client.download_blob()
        content = download_stream.readall()
        props = blob_client.get_blob_properties()

        return send_file(
            BytesIO(content),
            as_attachment=True,
            download_name=blob_name,
            mimetype=props.content_settings.content_type or 'application/octet-stream'
        )
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500


@app.route('/api/blob/<path:blob_name>', methods=['DELETE'])
def delete_blob(blob_name):
    try:
        blob_service_client = BlobServiceClient.from_connection_string(os.getenv('AZURE_STORAGE_CONNECTION_STRING'))
        container_name = os.getenv('AZURE_STORAGE_CONTAINER', 'uploads')
        blob_client = blob_service_client.get_blob_client(container=container_name, blob=blob_name)

        blob_client.delete_blob()
        return jsonify({'status': 'success', 'message': f'Blob {blob_name} deleted'})
    except Exception as e:
        return jsonify({'error': str(e), 'status': 'error'}), 500

if __name__ == '__main__':
    debug_mode = os.getenv('FLASK_DEBUG', 'false').lower() == 'true'
    port = int(os.getenv('PORT', '5000'))
    app.run(host='0.0.0.0', port=port, debug=debug_mode)
