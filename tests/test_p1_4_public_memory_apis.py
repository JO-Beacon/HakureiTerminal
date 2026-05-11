import asyncio
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from GensokyoAI.core.event_listeners import MemoryServiceListeners
from GensokyoAI.core.events import Event, EventBus, SystemEvent
from GensokyoAI.memory.topic_store import TopicAwareStore
from GensokyoAI.memory.types import TopicMemoryType
from GensokyoAI.memory.working import WorkingMemoryManager


class WorkingMemoryRollbackTests(unittest.TestCase):
    def test_rollback_messages_removes_recent_messages_and_returns_count(self):
        memory = WorkingMemoryManager(max_turns=10)
        memory.add_message("user", "1")
        memory.add_message("assistant", "2")
        memory.add_message("user", "3")

        removed = memory.rollback_messages(2)

        self.assertEqual(removed, 2)
        self.assertEqual(memory.get_context(), [{"role": "user", "content": "1"}])

    def test_rollback_messages_ignores_non_positive_count(self):
        memory = WorkingMemoryManager(max_turns=10)
        memory.add_message("user", "1")

        self.assertEqual(memory.rollback_messages(0), 0)
        self.assertEqual(memory.rollback_messages(-1), 0)
        self.assertEqual(len(memory), 1)

    def test_rollback_turns_removes_two_messages_per_turn(self):
        memory = WorkingMemoryManager(max_turns=10)
        for index in range(5):
            role = "user" if index % 2 == 0 else "assistant"
            memory.add_message(role, str(index))

        removed = memory.rollback_turns(2)

        self.assertEqual(removed, 4)
        self.assertEqual(memory.get_context(), [{"role": "user", "content": "0"}])


class TopicAwareStorePublicApiTests(unittest.TestCase):
    def test_find_topic_by_name_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TopicAwareStore(Path(tmp) / "topics.json")

            topic = asyncio.run(store.add_async("灵梦喜欢喝茶", topic_name="Reimu"))

            self.assertIs(store.find_topic_by_name("reimu"), topic)
            self.assertIs(store.find_topic_by_name("REIMU"), topic)

    def test_update_topic_memory_appends_correction_memory_and_persists(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "topics.json"
            store = TopicAwareStore(path)
            topic = asyncio.run(store.add_async("旧设定", topic_name="设定"))
            self.assertIsNotNone(topic)
            assert topic is not None
            original_last_message_id = topic.message_ids[-1]

            updated = asyncio.run(store.update_topic_memory("设定", "新设定"))

            self.assertIsNotNone(updated)
            assert updated is not None
            self.assertEqual(updated.name, "设定")
            self.assertEqual(len(updated.message_ids), 2)
            appended_memory_id = updated.message_ids[-1]
            appended_memory = store._memories[appended_memory_id]
            self.assertEqual(appended_memory.content, "新设定")
            self.assertEqual(appended_memory.memory_type, TopicMemoryType.CORRECTION)
            self.assertEqual(appended_memory.supersedes, original_last_message_id)
            self.assertTrue(path.exists())

    def test_update_topic_memory_returns_none_for_missing_topic(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TopicAwareStore(Path(tmp) / "topics.json")

            updated = asyncio.run(store.update_topic_memory("不存在", "内容"))

            self.assertIsNone(updated)


class MemoryServiceListenersPublicApiTests(unittest.TestCase):
    def test_memory_update_listener_uses_store_public_update_api(self):
        event_bus = EventBus(enable_trace=False)
        event_bus.respond = MagicMock()
        topic = SimpleNamespace(name="设定")
        store = SimpleNamespace(update_topic_memory=AsyncMock(return_value=topic))
        semantic_memory = SimpleNamespace(store=store)
        agent = SimpleNamespace(semantic_memory=semantic_memory)
        listener = MemoryServiceListeners(agent, event_bus)  # type: ignore[arg-type]
        event = Event(
            type=SystemEvent.MEMORY_SEMANTIC_UPDATED,
            source="tool.update_memory",
            data={"topic_name": "设定", "new_content": "新设定", "reason": "测试"},
        )

        asyncio.run(listener.on_memory_update_request(event))

        store.update_topic_memory.assert_called_once_with("设定", "新设定")
        event_bus.respond.assert_called_once_with(event, {"topic_name": "设定", "updated": True})

    def test_memory_update_listener_responds_none_for_missing_topic(self):
        event_bus = EventBus(enable_trace=False)
        event_bus.respond = MagicMock()
        store = SimpleNamespace(update_topic_memory=AsyncMock(return_value=None))
        semantic_memory = SimpleNamespace(store=store)
        agent = SimpleNamespace(semantic_memory=semantic_memory)
        listener = MemoryServiceListeners(agent, event_bus)  # type: ignore[arg-type]
        event = Event(
            type=SystemEvent.MEMORY_SEMANTIC_UPDATED,
            source="tool.update_memory",
            data={"topic_name": "不存在", "new_content": "新设定"},
        )

        asyncio.run(listener.on_memory_update_request(event))

        store.update_topic_memory.assert_called_once_with("不存在", "新设定")
        event_bus.respond.assert_called_once_with(event, None)


if __name__ == "__main__":
    unittest.main()
