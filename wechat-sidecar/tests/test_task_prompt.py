import sys
import os
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("HEALTH_CHAT_ENABLED", "false")
import elder_assistant  # noqa: E402


class TaskPromptTest(unittest.TestCase):
    """系统提示必须带上当天任务，否则模型只会寒暄，不知道自己该干嘛。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = elder_assistant.DB_PATH
        elder_assistant.DB_PATH = Path(self.temp.name) / "elder.sqlite3"
        elder_assistant._PRACTICE_LOG.clear()
        elder_assistant.init_db()
        self.elder = "wx_task_prompt"
        with elder_assistant._db() as conn:
            # 这两张表由 create_app 侧建，纯逻辑测试里自己补上。
            conn.execute("CREATE TABLE IF NOT EXISTS game_session_identity (session_id TEXT PRIMARY KEY, channel_account_id TEXT NOT NULL)")
            conn.execute("CREATE TABLE IF NOT EXISTS game_event_identity (event_id TEXT PRIMARY KEY, sender_id TEXT NOT NULL, channel_account_id TEXT NOT NULL)")
            conn.execute("DELETE FROM medication_courses WHERE elder_id = ?", (self.elder,))
            conn.execute("DELETE FROM health_events WHERE elder_id = ?", (self.elder,))
            conn.execute("DELETE FROM chat_history WHERE elder_id = ?", (self.elder,))

    def tearDown(self):
        elder_assistant.DB_PATH = self.previous
        self.temp.cleanup()

    def add_course(self):
        now = elder_assistant._now()
        with elder_assistant._db() as conn:
            conn.execute(
                "INSERT INTO medication_courses(course_id, elder_id, drug_name, duration_days, times_per_day, "
                "when_take, start_date, end_date, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                ("course_task", self.elder, "苯磺酸氨氯地平", 7, "1次/天", "早饭后",
                 now[:10], "2099-01-01", "active", now, now),
            )

    def log_medication(self):
        with elder_assistant._db() as conn:
            conn.execute(
                "INSERT INTO health_events(event_id, elder_id, event_type, payload_json, risk_level, "
                "family_share, source, created_at) VALUES (?,?,?,?,?,?,?,?)",
                ("evt_task", self.elder, "medication_taken", '{"statement":"已服药"}',
                 "routine", 1, "test", elder_assistant._now()),
            )

    def log_reply(self, text):
        with elder_assistant._db() as conn:
            conn.execute(
                "INSERT INTO chat_history(elder_id, role, text, created_at) VALUES (?,?,?,?)",
                (self.elder, "assistant", text, elder_assistant._now()),
            )

    def test_unconfirmed_medication_is_the_focus(self):
        self.add_course()
        block = elder_assistant._task_block(self.elder)
        self.assertIn("苯磺酸氨氯地平", block)
        self.assertIn("今天服药：还没记上", block)
        self.assertIn("本轮重点", block)
        self.assertIn("吃了没有", block)

    def test_confirmed_medication_is_not_pushed_again(self):
        self.add_course()
        self.log_medication()
        block = elder_assistant._task_block(self.elder)
        self.assertIn("今天服药：已经记上了", block)
        self.assertIn("不要再提药", block)

    def test_no_course_asks_what_they_are_taking(self):
        block = elder_assistant._task_block(self.elder)
        self.assertIn("没有登记在吃的药", block)
        self.assertIn("在吃什么药", block)

    def test_repeat_asking_is_discouraged(self):
        self.add_course()
        self.log_reply("早饭后那顿药吃了没有？")
        block = elder_assistant._task_block(self.elder)
        self.assertIn("已经问过用药", block)
        self.assertNotIn("问一句吃了没有", block)

    def test_today_events_are_summarised(self):
        self.add_course()
        with elder_assistant._db() as conn:
            conn.execute(
                "INSERT INTO health_events(event_id, elder_id, event_type, payload_json, risk_level, "
                "family_share, source, created_at) VALUES (?,?,?,?,?,?,?,?)",
                ("evt_sym", self.elder, "symptom_reported", '{"text":"有点头晕"}',
                 "routine", 1, "test", elder_assistant._now()),
            )
        block = elder_assistant._task_block(self.elder)
        self.assertIn("说过不舒服", block)

    def test_today_bounds_wrap_local_midnight(self):
        start, end = elder_assistant._local_today_utc_bounds()
        self.assertLess(start, end)
        self.assertTrue(start.endswith("+00:00"))
        self.assertTrue(end.endswith("+00:00"))

    def test_system_prompt_has_persona_and_task(self):
        self.add_course()
        system = elder_assistant._system_prompt(self.elder)
        self.assertIn("不是闲聊机器人", system)
        self.assertIn("【今天的任务】", system)
        self.assertIn("苯磺酸氨氯地平", system)

    def test_bare_ack_after_question_counts_as_medication(self):
        self.add_course()
        self.log_reply("早饭后那片苯磺酸氨氯地平，今天吃上了没有？")
        self.assertTrue(elder_assistant._awaiting_medication_answer(self.elder))
        result = elder_assistant.handle_message({"elder_id": self.elder, "text": "吃了"})
        self.assertEqual(result["intent"], "medication_taken")

    def test_bare_ack_without_question_stays_a_meal(self):
        self.add_course()
        result = elder_assistant.handle_message({"elder_id": self.elder, "text": "吃了"})
        self.assertEqual(result["intent"], "meal_log")

    def test_ack_ignored_once_medication_logged(self):
        self.add_course()
        self.log_medication()
        self.log_reply("今天那颗药吃了没有？")
        self.assertFalse(elder_assistant._awaiting_medication_answer(self.elder))


    def test_bare_drug_name_after_question_opens_course(self):
        self.log_reply("你现在每天在吃什么药？说个药名就行。")
        self.assertTrue(elder_assistant._awaiting_drug_name_answer(self.elder))
        result = elder_assistant.handle_message({"elder_id": self.elder, "text": "苯磺酸氨氯地平"})
        self.assertEqual(result["intent"], "medication_course")
        self.assertIn("苯磺酸氨氯地平", result["reply"])

    def test_bare_drug_name_without_question_stays_chat(self):
        self.assertEqual(elder_assistant._intent("苯磺酸氨氯地平", []), "chat")
        self.assertTrue(elder_assistant._looks_like_drug_name("苯磺酸氨氯地平"))
        self.assertFalse(elder_assistant._looks_like_drug_name("没有了"))


if __name__ == "__main__":
    unittest.main()
