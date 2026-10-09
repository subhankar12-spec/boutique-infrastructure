import importlib.util
import json
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts/summarize-plan.py"
SPEC = importlib.util.spec_from_file_location("summary", SOURCE)
summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summary)


class PlanRedaction(unittest.TestCase):
    def test_sensitive_values_and_outputs_never_enter_review_summary(self):
        marker = "TEST_VALUE_MUST_NOT_APPEAR"
        plan = {"terraform_version": "1.11.4", "variables": {"password": marker},
                "planned_values": {"secret_string": marker}, "output_changes": {"queue": marker},
                "resource_changes": [
                    {"address": "aws_db_instance.queue", "type": "aws_db_instance",
                     "change": {"actions": ["delete", "create"], "before": {"password": marker},
                                "after": {"secret_string": marker}, "after_sensitive": {"secret_string": True}}},
                    {"address": "aws_kms_key.existing", "type": "aws_kms_key",
                     "change": {"actions": ["no-op"], "before": marker, "after": marker}}]}
        result = summary.summarize(plan)
        self.assertNotIn(marker, json.dumps(result))
        self.assertEqual(result["action_counts"], {"delete/create": 1})
        self.assertEqual(result["resources"], [{"address": "aws_db_instance.queue", "type": "aws_db_instance", "actions": ["delete", "create"]}])


if __name__ == "__main__":
    unittest.main()
