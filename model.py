#!/usr/bin/env python3
import subprocess
import tempfile
import signal
import fcntl
import time
import json
import os
from contextlib import contextmanager

QUERY_LATEST = (
    "SELECT m.ROWID, m.is_from_me, m.text, COALESCE(h.id, '') "
    "FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID "
    "ORDER BY m.date DESC LIMIT 1;"
)
QUERY_SINCE = (
    "SELECT m.ROWID, m.is_from_me, m.text, COALESCE(h.id, '') "
    "FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID "
    "WHERE m.ROWID > {hwm} AND m.is_from_me = 0 AND m.text IS NOT NULL AND m.text != '' "
    "ORDER BY m.ROWID ASC;"
)

REQUIRED_CONFIG_KEYS = {
    'name': str, 'personalDescription': str,
    'moods': dict, 'phoneListMode': str, 'phoneNumbers': list,
}
RESERVED_MOOD_NAMES = {'Reply', 'reply', 'sender', 'message', 'time', 'replies'}

def normalize_phone(number):
    if not number or '@' in number:
        return number or ''
    digits = ''.join(c for c in number if c.isdigit())
    return ('+' + digits) if number.startswith('+') else (digits or number)

def validate_config(config):
    for key, expected_type in REQUIRED_CONFIG_KEYS.items():
        if key not in config:
            return f"missing required key '{key}'"
        if not isinstance(config[key], expected_type):
            return f"'{key}' must be {expected_type.__name__}, got {type(config[key]).__name__}"
    if config['phoneListMode'] not in ('Include', 'Exclude'):
        return f"'phoneListMode' must be 'Include' or 'Exclude', got '{config['phoneListMode']}'"
    if not config['moods']:
        return "need at least 1 mood"
    bad = RESERVED_MOOD_NAMES & set(config['moods'])
    if bad:
        return f"mood names collide with reserved keys: {bad}"
    for k, v in config['moods'].items():
        if not isinstance(k, str) or not isinstance(v, str):
            return f"mood entries must be string:string, got {type(k).__name__}:{type(v).__name__}"
    return None

def gen_replies(config, recent_text):
    import ollama
    moods = config['moods']
    mood_entries = ", ".join(f'{json.dumps(m)}: {json.dumps(moods[m])}' for m in moods)
    system_prompt = (
        f'You are {config["name"]}. {config["name"]} was asked about their personality '
        f'so take notes and form a base tone of {config["name"]}: '
        f'"{config["personalDescription"]}" '
        f'You have {len(moods)} moods. Your moods are: {{{mood_entries}}}. '
        f'As {config["name"]}, you will be given new texts from a sender. '
        f'You MUST output **EXACTLY {len(moods)} RESPONSES**. '
        f'Each text response should be a response as though you were in the given mood. '
        f'If moods were {{"Happy": "Very nice and upbeat.", "Sad": "Very short and pessimistic", '
        f'"Angry": "Quick to snap and not very nice"}} and the text was "Hi", you respond with '
        f'{{"Happy": "Hi! How are you, is everything good?", '
        f'"Sad": "Hey, how are you? I\'m hanging in there...", '
        f'"Angry": "Yeah, what do you need?"}}. '
        f'The goal is to always return a dictionary and the dictionary must have {len(moods)} entries.'
    )
    tries = 5
    while tries > 0:
        try:
            out = ollama.chat(
                model="llama3.1:8b",
                format="json",
                options={"temperature": 0.8},
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": recent_text}
                ]
            )["message"]["content"]
            out = json.loads(out)
        except Exception as e:
            tries -= 1
            print(f"[GENERATING] Error: {e}, retry.\n")
            continue
        if not isinstance(out, dict):
            tries -= 1
            print("[GENERATING] Non-dict JSON from model, retry.\n")
            continue
        if sorted(out) == sorted(config['moods']):
            if all(isinstance(v, str) for v in out.values()):
                return out
            tries -= 1
            print("[GENERATING] Non-string values in response, retry.\n")
            continue
        tries -= 1
        print(f"[GENERATING] Key mismatch: expected {sorted(config['moods'])} got {sorted(out)}, retry.\n")
    fallback = {}
    for mood in config['moods']:
        fallback[mood] = ""
    return fallback

def _phones_match(a, b):
    da = ''.join(c for c in (a or '') if c.isdigit())
    db = ''.join(c for c in (b or '') if c.isdigit())
    if not da or not db:
        return (a or '') == (b or '')
    if da == db:
        return True
    shorter, longer = (da, db) if len(da) <= len(db) else (db, da)
    return len(shorter) >= 7 and longer.endswith(shorter)

def should_process(config, number, rowid, recent_rowid):
    mode = config['phoneListMode']
    nums = config['phoneNumbers']
    if mode == 'Include':
        allowed = any(_phones_match(number, n) for n in nums)
    else:
        allowed = not any(_phones_match(number, n) for n in nums)
    return allowed and rowid != recent_rowid

@contextmanager
def _file_lock(filepath):
    lock_path = filepath + '.lock'
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        yield
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

def atomic_write_json(filepath, data):
    dir_name = os.path.dirname(os.path.abspath(filepath))
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=4)
        os.replace(tmp_path, filepath)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

def _safe_rowid(value):
    if not str(value).isdigit():
        raise ValueError(f"invalid ROWID: {value!r}")
    return str(value)

def query_db(db_path, sql):
    try:
        result = subprocess.run(
            ['sqlite3', '-separator', '\x1f', db_path, sql],
            capture_output=True, text=True
        )
    except FileNotFoundError:
        print("[FATAL] sqlite3 not found on PATH. Install it or ensure it is accessible.\n")
        raise SystemExit(1)
    if result.returncode != 0:
        if result.stderr.strip():
            print(f"[DB] sqlite3 error: {result.stderr.strip()}\n")
        return None
    return result.stdout.strip()

if __name__ == '__main__':
    try:
        with open('config.json', 'r') as file:
            config = json.load(file)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[FATAL] Cannot load config.json: {e}\n")
        raise SystemExit(1)
    err = validate_config(config)
    if err:
        print(f"[FATAL] Invalid config.json: {err}\n")
        raise SystemExit(1)
    print("[INIT] Config loaded.\n")
    recent_rowid = "0"
    path = os.path.expanduser("~/Library/Messages/chat.db")
    if os.path.exists(path):
        print("[INIT] Database found.\n")
    else:
        print("[INIT] Database not found at expected path, will retry.\n")
    _shutdown = [False]
    def _handle_sigterm(signum, frame):
        _shutdown[0] = True
    signal.signal(signal.SIGTERM, _handle_sigterm)

    while not _shutdown[0]:
        row = query_db(path, QUERY_LATEST)
        if row is not None:
            parts = row.split("\x1f", 3)
            if len(parts) >= 1 and parts[0].strip():
                recent_rowid = parts[0].strip()
                print(f"[INIT] Watching for messages after ROWID {recent_rowid}.\n")
                break
        time.sleep(1)

    poll_count = 0
    while not _shutdown[0]:
        try:
            raw = query_db(path, QUERY_SINCE.format(hwm=_safe_rowid(recent_rowid)))
            if not raw:
                if poll_count % 100 == 0:
                    print("[WAITING] Fetching text with content ...\n")
                poll_count += 1
                time.sleep(1)
                continue
            poll_count = 0
            for row in raw.split("\n"):
                row = row.strip()
                if not row or _shutdown[0]:
                    continue
                parts = row.split("\x1f", 3)
                if len(parts) < 4:
                    continue
                rowid, _, text, number = parts[0].strip(), parts[1].strip(), parts[2].strip(), normalize_phone(parts[3].strip())
                try:
                    with open('config.json', 'r') as file:
                        config = json.load(file)
                except (FileNotFoundError, json.JSONDecodeError) as e:
                    print(f"[ERROR] Cannot reload config.json: {e}\n")
                    recent_rowid = rowid
                    continue
                err = validate_config(config)
                if err:
                    print(f"[ERROR] Invalid config.json: {err}\n")
                    recent_rowid = rowid
                    continue
                if not should_process(config, number, rowid, recent_rowid):
                    recent_rowid = rowid
                    continue
                recent_rowid = rowid
                replies = {'Reply': "Refresh"}
                print(f"[RUN] New text from {number} found.\n")
                while replies.get('Reply') == "Refresh":
                    try:
                        with open('config.json', 'r') as file:
                            config = json.load(file)
                    except (FileNotFoundError, json.JSONDecodeError) as e:
                        print(f"[ERROR] Cannot reload config.json: {e}\n")
                        break
                    err = validate_config(config)
                    if err:
                        print(f"[ERROR] Invalid config.json: {err}\n")
                        break
                    print(f"[GENERATING] {len(config['moods'])} new responses will be generated.\n")
                    start = time.time()
                    replies = gen_replies(config, text)
                    end = time.time()
                    elapsed = f"{end-start:.2f}"
                    print(f"[FINISH] Done generating in {elapsed} seconds.\n")
                    replies.update({'Reply': "", 'sender': number, 'message': text, 'time': elapsed})
                    try:
                        print("[WRITING] Writing to replies.json.\n")
                        with _file_lock('replies.json'):
                            atomic_write_json('replies.json', replies)
                    except Exception as e:
                        print(f"[ERROR] Failed to write replies.json: {e}\n")
                        break
                    wait_count = 0
                    while replies.get('Reply') == "":
                        try:
                            with _file_lock('replies.json'):
                                with open('replies.json', 'r') as file:
                                    replies = json.load(file)
                        except (FileNotFoundError, json.JSONDecodeError) as e:
                            print(f"[ERROR] Cannot read replies.json: {e}\n")
                            time.sleep(0.5)
                            continue
                        if wait_count % 100 == 0:
                            print("[WAITING] User input ...\n")
                        wait_count += 1
                        time.sleep(0.5)
                if replies.get('Reply') == "Refresh":
                    print("[ERROR] Exited refresh loop without resolution, skipping.\n")
                elif replies.get('Reply') == "Ignore":
                    print("[FINISH] Not sending text.\n")
                elif replies.get('Reply'):
                    reply_key = replies['Reply']
                    reply_text = replies.get(reply_key)
                    if reply_text is None:
                        print(f"[ERROR] Reply key '{reply_key}' not found in replies, skipping send.\n")
                    elif not reply_text.strip():
                        print(f"[ERROR] Reply text for '{reply_key}' is empty, skipping send.\n")
                    else:
                        print("[FINISH] Sending text.\n")
                        try:
                            result = subprocess.run(['osascript', 'send_imessage.osa', number, reply_text], capture_output=True, text=True, timeout=30)
                            if result.returncode != 0:
                                detail = result.stderr.strip() if result.stderr else f"code {result.returncode}"
                                print(f"[ERROR] osascript failed: {detail}\n")
                        except subprocess.TimeoutExpired:
                            print("[ERROR] osascript timed out after 30s.\n")
        except Exception as e:
            print(f"[ERROR] Unexpected error in main loop: {e}\n")
        time.sleep(1)
