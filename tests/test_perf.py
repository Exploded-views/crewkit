"""Tests for tools/perf.py: the budget logic, not the timings themselves."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "perf.py"


def load():
    spec = importlib.util.spec_from_file_location("perf", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Perf(unittest.TestCase):
    def setUp(self):
        self.perf = load()

    def test_p95_of_twenty_samples_is_the_nineteenth_smallest(self):
        self.assertEqual(self.perf.p95(list(range(1, 21))), 19)

    def test_p95_is_order_independent(self):
        self.assertEqual(self.perf.p95([5, 1, 9, 3]), self.perf.p95([1, 3, 5, 9]))

    def test_under_budget_passes(self):
        self.assertEqual(self.perf.over_budget({"a": 50.0}, {"a": {"p95_ms": 100}}, 1.0), [])

    def test_over_budget_fails_and_names_the_scenario(self):
        fails = self.perf.over_budget({"a": 150.0}, {"a": {"p95_ms": 100}}, 1.0)
        self.assertEqual(len(fails), 1)
        self.assertIn("a", fails[0])

    def test_headroom_widens_the_budget(self):
        self.assertEqual(self.perf.over_budget({"a": 150.0}, {"a": {"p95_ms": 100}}, 2.0), [])

    def test_a_measured_scenario_without_a_budget_fails(self):
        fails = self.perf.over_budget({"a": 1.0, "b": 1.0}, {"a": {"p95_ms": 100}}, 1.0)
        self.assertTrue(any("b" in f and "no budget" in f for f in fails), fails)

    def test_a_budget_with_no_scenario_fails(self):
        fails = self.perf.over_budget({"a": 1.0}, {"a": {"p95_ms": 100}, "gone": {"p95_ms": 5}}, 1.0)
        self.assertTrue(any("gone" in f for f in fails), fails)

    def test_best_of_trials_ignores_a_noisy_trial(self):
        trials = [[1, 2, 3, 50, 60], [1, 2, 3, 4, 5], [1, 2, 3, 40, 45]]
        self.assertEqual(self.perf.best_p95(trials), self.perf.p95([1, 2, 3, 4, 5]))

    def test_trials_come_from_the_budget_file(self):
        self.assertEqual(self.perf.trials({"trials": 5}), 5)
        self.assertEqual(self.perf.trials({}), 3)

    def test_headroom_only_in_ci(self):
        cfg = {"ci_headroom": 2.5}
        self.assertEqual(self.perf.headroom(cfg, {"CI": "true"}), 2.5)
        self.assertEqual(self.perf.headroom(cfg, {}), 1.0)

    def test_the_committed_budgets_cover_every_scenario(self):
        cfg = json.loads((SCRIPT.parent.parent / "perf-budgets.json").read_text())
        self.assertEqual(set(cfg["budgets"]), set(self.perf.SCENARIOS))
        self.assertLessEqual(cfg["budgets"]["shared-index-150-notes"]["p95_ms"], 100)


if __name__ == "__main__":
    unittest.main()
