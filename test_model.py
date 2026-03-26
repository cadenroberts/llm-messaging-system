#!/usr/bin/env python3
import json
import os
import tempfile
import unittest

from model import (
    validate_config,
    should_process,
    normalize_phone,
    _phones_match,
    atomic_write_json,
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


if __name__ == '__main__':
    unittest.main()
