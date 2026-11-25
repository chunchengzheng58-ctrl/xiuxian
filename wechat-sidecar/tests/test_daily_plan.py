"""老人问“今天做什么/该锻炼什么”时的用药引导，以及跨轮次的主动用药提醒。"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("HEALTH_CHAT_ENABLED", "false")

import elder_assistant as ea  # noqa: E402


class DailyPlanTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        ea.DB_PATH = Path(self.temp.name) / "elder.sqlite3"
        ea._PRACTICE_LOG.clear()
        ea.init_db()
        # 这张表由 create_app 侧建，纯逻辑测试里自己补上。
        with ea._db() as conn:
            conn.execute("CREATE TABLE IF NOT EXISTS game_session_identity (session_id TEXT PRIMARY KEY, channel_account_id TEXT NOT NULL)")
        self.elder = "wx_test_elder"

    def tearDown(self):
        self.temp.cleanup()

    def add_course(self, drug="苯磺酸氨氯地平"):
        with ea._db() as conn:
            conn.execute(
                "INSERT INTO medication_courses(course_id, elder_id, drug_name, duration_days, times_per_day, "
                "when_take, start_date, end_date, status, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
                ("course_1", self.elder, drug, 7, "1次/天", "饭后", "2026-11-25", "2099-01-01", ea._now(), ea._now()),
            )

    def log_medication_today(self):
        now = ea._now()
        with ea._db() as conn:
            conn.execute(
                "INSERT INTO health_events(event_id, elder_id, event_type, payload_json, risk_level, "
                "family_share, source, created_at) VALUES (?, ?, 'medication_taken', '{}', 'routine', 1, 'test', ?)",
                ("event_1", self.elder, now),
            )

    def ask(self, text):
        return ea.handle_message({"elder_id": self.elder, "text": text})

    def test_exercise_question_answers_with_medication_first(self):
        self.add_course()
        result = self.ask("我今天需要锻炼什么")
        self.assertEqual(result["intent"], "daily_plan")
        self.assertIn("苯磺酸氨氯地平", result["reply"])
        self.assertIn("走20分钟", result["reply"])
        self.assertNotIn("想聊点什么", result["reply"])

    def test_exercise_question_without_course_still_answers(self):
        result = self.ask("今天该干什么")
        self.assertEqual(result["intent"], "daily_plan")
        self.assertIn("没有登记在吃的药", result["reply"])
        self.assertIn("走20分钟", result["reply"])

    def test_daily_plan_does_not_repeat_drug_already_logged(self):
        self.add_course()
        self.log_medication_today()
        reply = self.ask("今天要注意什么")["reply"]
        self.assertIn("已经记上一次了", reply)
        self.assertIn("苯磺酸氨氯地平", reply)

    def test_proactive_line_once_then_cools_down(self):
        self.add_course()
        first = self.ask("你好")["reply"]
        self.assertIn("还没记上", first)
        second = self.ask("在吗")["reply"]
        self.assertNotIn("还没记上", second)

    def test_proactive_line_skipped_when_already_logged(self):
        self.add_course()
        self.log_medication_today()
        self.assertNotIn("还没记上", self.ask("你好")["reply"])

    def test_proactive_line_skipped_without_course(self):
        self.assertNotIn("还没记上", self.ask("你好")["reply"])


if __name__ == "__main__":
    unittest.main()
