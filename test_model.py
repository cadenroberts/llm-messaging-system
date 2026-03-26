#!/usr/bin/env python3
import json
import os
import tempfile
import unittest
from unittest.mock import patch, MagicMock

from model import (
    validate_config,
    should_process,
    normalize_phone,
    _phones_match,
    atomic_write_json,
    query_db,
    gen_replies,
    _safe_rowid,
    REQUIRED_CONFIG_KEYS,
    RESERVED_MOOD_NAMES,
)

VALID_CONFIG = {
    'name': 'Caden Roberts',
    'personalDescription': 'Test description',
    'moods': {'Happy': 'Nice', 'Sad': 'Down'},
    'phoneListMode': 'Exclude',
    'phoneNumbers': [],
}


class TestValidateConfig(unittest.TestCase):
    def test_valid(self):
        self.assertIsNone(validate_config(VALID_CONFIG))

    def test_missing_key(self):
        for key in REQUIRED_CONFIG_KEYS:
            cfg = dict(VALID_CONFIG)
            del cfg[key]
            self.assertIsNotNone(validate_config(cfg))

    def test_wrong_type(self):
        cfg = dict(VALID_CONFIG)
        cfg['name'] = 123
        self.assertIsNotNone(validate_config(cfg))

    def test_bad_phone_list_mode(self):
        cfg = dict(VALID_CONFIG)
        cfg['phoneListMode'] = 'Neither'
        self.assertIsNotNone(validate_config(cfg))

    def test_empty_moods(self):
        cfg = dict(VALID_CONFIG)
        cfg['moods'] = {}
        self.assertIsNotNone(validate_config(cfg))

    def test_reserved_mood_name(self):
        for name in RESERVED_MOOD_NAMES:
            cfg = dict(VALID_CONFIG)
            cfg['moods'] = {name: 'desc'}
            self.assertIsNotNone(validate_config(cfg), f'reserved name {name!r} should fail')

    def test_non_string_mood_value(self):
        cfg = dict(VALID_CONFIG)
        cfg['moods'] = {'Happy': 123}
        self.assertIsNotNone(validate_config(cfg))


class TestNormalizePhone(unittest.TestCase):
    def test_e164(self):
        self.assertEqual(normalize_phone('+15551234567'), '+15551234567')

    def test_formatted(self):
        self.assertEqual(normalize_phone('+1 (555) 123-4567'), '+15551234567')

    def test_no_plus(self):
        self.assertEqual(normalize_phone('5551234567'), '5551234567')

    def test_empty(self):
        self.assertEqual(normalize_phone(''), '')

    def test_none(self):
        self.assertEqual(normalize_phone(None), '')

    def test_email_passthrough(self):
        self.assertEqual(normalize_phone('user@icloud.com'), 'user@icloud.com')

    def test_spaces_dashes(self):
        self.assertEqual(normalize_phone('555 123-4567'), '5551234567')


class TestPhonesMatch(unittest.TestCase):
    def test_exact_e164(self):
        self.assertTrue(_phones_match('+15551234567', '+15551234567'))

    def test_country_code_prefix(self):
        self.assertTrue(_phones_match('+15551234567', '5551234567'))

    def test_country_code_symmetric(self):
        self.assertTrue(_phones_match('5551234567', '+15551234567'))

    def test_formatted_vs_e164(self):
        self.assertTrue(_phones_match('+1 (555) 123-4567', '+15551234567'))

    def test_different_numbers(self):
        self.assertFalse(_phones_match('+15551234567', '+15559999999'))

    def test_email_equal(self):
        self.assertTrue(_phones_match('user@icloud.com', 'user@icloud.com'))

    def test_email_different(self):
        self.assertFalse(_phones_match('user@icloud.com', 'other@icloud.com'))

    def test_short_no_false_positive(self):
        self.assertFalse(_phones_match('123456', '+15551234567'))

    def test_empty_both(self):
        self.assertTrue(_phones_match('', ''))

    def test_none_both(self):
        self.assertTrue(_phones_match(None, None))

    def test_seven_digit_suffix(self):
        self.assertTrue(_phones_match('1234567', '+15551234567'))

    def test_six_digit_no_match(self):
        self.assertFalse(_phones_match('234567', '+15551234567'))


class TestShouldProcess(unittest.TestCase):
    def _cfg(self, mode='Exclude', nums=None):
        cfg = dict(VALID_CONFIG)
        cfg['phoneListMode'] = mode
        cfg['phoneNumbers'] = nums or []
        return cfg

    def test_exclude_empty_list(self):
        self.assertTrue(should_process(self._cfg(), '+15551234567', '2', '1'))

    def test_exclude_blocked(self):
        self.assertFalse(should_process(
            self._cfg(nums=['+15551234567']), '+15551234567', '2', '1'))

    def test_include_allowed(self):
        self.assertTrue(should_process(
            self._cfg('Include', ['+15551234567']), '+15551234567', '2', '1'))

    def test_include_not_listed(self):
        self.assertFalse(should_process(
            self._cfg('Include', ['+15559999999']), '+15551234567', '2', '1'))

    def test_same_rowid(self):
        self.assertFalse(should_process(self._cfg(), '+15551234567', '5', '5'))

    def test_formatted_match(self):
        self.assertFalse(should_process(
            self._cfg(nums=['+1 (555) 123-4567']), '+15551234567', '2', '1'))

    def test_country_code_prefix_exclude(self):
        self.assertFalse(should_process(
            self._cfg(nums=['5551234567']), '+15551234567', '2', '1'))

    def test_country_code_prefix_include(self):
        self.assertTrue(should_process(
            self._cfg('Include', ['5551234567']), '+15551234567', '2', '1'))


class TestAtomicWriteJson(unittest.TestCase):
    def test_round_trip(self):
        data = {'key': 'value', 'count': 42}
        tmp = tempfile.mktemp(suffix='.json')
        try:
            atomic_write_json(tmp, data)
            with open(tmp) as f:
                self.assertEqual(json.load(f), data)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def test_overwrite(self):
        tmp = tempfile.mktemp(suffix='.json')
        try:
            atomic_write_json(tmp, {'a': 1})
            atomic_write_json(tmp, {'b': 2})
            with open(tmp) as f:
                self.assertEqual(json.load(f), {'b': 2})
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


class TestQueryDb(unittest.TestCase):
    @patch('model.subprocess.run')
    def test_success(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout='  123\x1f0\x1fhello\x1f+1555  \n')
        self.assertEqual(query_db('/fake/db', 'SELECT 1;'), '123\x1f0\x1fhello\x1f+1555')

    @patch('model.subprocess.run')
    def test_empty_stdout(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0, stdout='')
        self.assertEqual(query_db('/fake/db', 'SELECT 1;'), '')

    @patch('model.subprocess.run')
    def test_nonzero_returncode(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stderr='error msg')
        self.assertIsNone(query_db('/fake/db', 'SELECT 1;'))

    @patch('model.subprocess.run')
    def test_nonzero_empty_stderr(self, mock_run):
        mock_run.return_value = MagicMock(returncode=1, stderr='')
        self.assertIsNone(query_db('/fake/db', 'SELECT 1;'))

    @patch('model.subprocess.run', side_effect=FileNotFoundError)
    def test_sqlite3_missing(self, mock_run):
        with self.assertRaises(SystemExit):
            query_db('/fake/db', 'SELECT 1;')


class TestGenReplies(unittest.TestCase):
    def _cfg(self):
        return dict(VALID_CONFIG)

    def _mock_ollama(self):
        import sys
        m = MagicMock()
        patcher = patch.dict(sys.modules, {'ollama': m})
        patcher.start()
        self.addCleanup(patcher.stop)
        return m

    def test_correct_response(self):
        m = self._mock_ollama()
        m.chat.return_value = {
            'message': {'content': json.dumps({'Happy': 'Hey!', 'Sad': 'Meh'})}
        }
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': 'Hey!', 'Sad': 'Meh'})
        self.assertEqual(m.chat.call_count, 1)

    def test_key_mismatch_then_success(self):
        m = self._mock_ollama()
        m.chat.side_effect = [
            {'message': {'content': json.dumps({'Wrong': 'key'})}},
            {'message': {'content': json.dumps({'Happy': 'Hey!', 'Sad': 'Meh'})}},
        ]
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': 'Hey!', 'Sad': 'Meh'})
        self.assertEqual(m.chat.call_count, 2)

    def test_non_dict_then_success(self):
        m = self._mock_ollama()
        m.chat.side_effect = [
            {'message': {'content': '"just a string"'}},
            {'message': {'content': json.dumps({'Happy': 'Hey!', 'Sad': 'Meh'})}},
        ]
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': 'Hey!', 'Sad': 'Meh'})

    def test_non_string_values_then_success(self):
        m = self._mock_ollama()
        m.chat.side_effect = [
            {'message': {'content': json.dumps({'Happy': 123, 'Sad': 'Meh'})}},
            {'message': {'content': json.dumps({'Happy': 'Hey!', 'Sad': 'Meh'})}},
        ]
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': 'Hey!', 'Sad': 'Meh'})

    def test_exception_then_success(self):
        m = self._mock_ollama()
        m.chat.side_effect = [
            RuntimeError('connection refused'),
            {'message': {'content': json.dumps({'Happy': 'Hey!', 'Sad': 'Meh'})}},
        ]
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': 'Hey!', 'Sad': 'Meh'})

    def test_all_retries_exhausted_returns_fallback(self):
        m = self._mock_ollama()
        m.chat.side_effect = RuntimeError('fail')
        result = gen_replies(self._cfg(), 'Hi')
        self.assertEqual(result, {'Happy': '', 'Sad': ''})
        self.assertEqual(m.chat.call_count, 5)


class TestSQLIntegration(unittest.TestCase):
    """Run QUERY_LATEST and QUERY_SINCE against a real temporary SQLite database."""

    def setUp(self):
        import sqlite3 as _sqlite3
        self._tmp = tempfile.NamedTemporaryFile(suffix='.db', delete=False)
        self._tmp.close()
        self.db_path = self._tmp.name
        conn = _sqlite3.connect(self.db_path)
        conn.executescript("""
            CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY,
                id TEXT NOT NULL
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                handle_id INTEGER,
                is_from_me INTEGER DEFAULT 0,
                text TEXT,
                date INTEGER DEFAULT 0
            );
            INSERT INTO handle (ROWID, id) VALUES (1, '+15551234567');
            INSERT INTO handle (ROWID, id) VALUES (2, '+15559999999');
            INSERT INTO message (ROWID, handle_id, is_from_me, text, date)
                VALUES (100, 1, 0, 'Hello', 1000);
            INSERT INTO message (ROWID, handle_id, is_from_me, text, date)
                VALUES (101, 1, 1, 'Hi back', 1001);
            INSERT INTO message (ROWID, handle_id, is_from_me, text, date)
                VALUES (102, 2, 0, 'Hey there', 1002);
            INSERT INTO message (ROWID, handle_id, is_from_me, text, date)
                VALUES (103, NULL, 0, '', 1003);
            INSERT INTO message (ROWID, handle_id, is_from_me, text, date)
                VALUES (104, 1, 0, 'Latest msg', 1004);
        """)
        conn.close()

    def tearDown(self):
        os.unlink(self.db_path)

    def test_query_latest_returns_highest_date(self):
        from model import QUERY_LATEST
        raw = query_db(self.db_path, QUERY_LATEST)
        self.assertIsNotNone(raw)
        parts = raw.split('\x1f', 3)
        self.assertEqual(parts[0], '104')
        self.assertEqual(parts[2], 'Latest msg')
        self.assertEqual(parts[3], '+15551234567')

    def test_query_since_filters_correctly(self):
        from model import QUERY_SINCE
        raw = query_db(self.db_path, QUERY_SINCE.format(hwm=_safe_rowid('100')))
        self.assertIsNotNone(raw)
        rows = [r for r in raw.split('\n') if r.strip()]
        rowids = [r.split('\x1f')[0] for r in rows]
        self.assertNotIn('100', rowids, 'should exclude hwm row')
        self.assertNotIn('101', rowids, 'should exclude is_from_me=1')
        self.assertNotIn('103', rowids, 'should exclude empty text')
        self.assertIn('102', rowids)
        self.assertIn('104', rowids)

    def test_query_since_returns_sender(self):
        from model import QUERY_SINCE
        raw = query_db(self.db_path, QUERY_SINCE.format(hwm=_safe_rowid('101')))
        rows = [r for r in raw.split('\n') if r.strip()]
        for row in rows:
            parts = row.split('\x1f', 3)
            if parts[0] == '102':
                self.assertEqual(parts[3], '+15559999999')
                return
        self.fail('ROWID 102 not found in results')

    def test_query_since_null_handle(self):
        from model import QUERY_SINCE
        raw = query_db(self.db_path, QUERY_SINCE.format(hwm=_safe_rowid('0')))
        rows = [r for r in raw.split('\n') if r.strip()]
        rowids = [r.split('\x1f')[0] for r in rows]
        self.assertNotIn('103', rowids, 'empty text row should be excluded')

    def test_query_since_no_new_messages(self):
        from model import QUERY_SINCE
        raw = query_db(self.db_path, QUERY_SINCE.format(hwm=_safe_rowid('999')))
        self.assertFalse(raw)

    def test_query_since_order_ascending(self):
        from model import QUERY_SINCE
        raw = query_db(self.db_path, QUERY_SINCE.format(hwm=_safe_rowid('0')))
        rows = [r for r in raw.split('\n') if r.strip()]
        rowids = [int(r.split('\x1f')[0]) for r in rows]
        self.assertEqual(rowids, sorted(rowids))


@unittest.skipUnless(
    os.environ.get('CI_LIVE_OLLAMA'),
    'requires running Ollama with llama3.1:8b (set CI_LIVE_OLLAMA=1)',
)
class TestLiveOllama(unittest.TestCase):

    def test_gen_replies_returns_correct_keys(self):
        result = gen_replies(VALID_CONFIG, 'Hello, how are you?')
        self.assertIsInstance(result, dict)
        self.assertEqual(sorted(result.keys()), sorted(VALID_CONFIG['moods'].keys()))
        for v in result.values():
            self.assertIsInstance(v, str)
            self.assertTrue(len(v) > 0, 'reply should not be empty')


class TestSafeRowid(unittest.TestCase):
    def test_valid_integer(self):
        self.assertEqual(_safe_rowid('12345'), '12345')

    def test_valid_zero(self):
        self.assertEqual(_safe_rowid('0'), '0')

    def test_rejects_non_numeric(self):
        with self.assertRaises(ValueError):
            _safe_rowid('12; DROP TABLE message;')

    def test_rejects_negative(self):
        with self.assertRaises(ValueError):
            _safe_rowid('-1')

    def test_rejects_empty(self):
        with self.assertRaises(ValueError):
            _safe_rowid('')

    def test_int_input(self):
        self.assertEqual(_safe_rowid(42), '42')


if __name__ == '__main__':
    unittest.main()
