import unittest


def move_module_in_config(config, from_region, from_name, to_region, before_name):
    if not config or not isinstance(config, dict):
        return False
    bar = config.setdefault("bar", {})
    layout = bar.setdefault("layout", {})
    from_entries = layout.setdefault(from_region, [])
    to_entries = layout.setdefault(to_region, [])

    def entry_id(entry):
        return entry if isinstance(entry, str) else (entry.get("id", "") if isinstance(entry, dict) else "")

    from_index = -1
    for i, e in enumerate(from_entries):
        if entry_id(e) == from_name:
            from_index = i
            break
    if from_index < 0:
        return False

    to_index = len(to_entries)
    if before_name:
        for j, e in enumerate(to_entries):
            if entry_id(e) == before_name:
                to_index = j
                break

    if from_region == to_region and from_index == to_index:
        return False

    moved = from_entries.pop(from_index)

    if from_region == to_region and from_index < to_index:
        to_index -= 1
    if to_index < 0:
        to_index = 0
    if to_index > len(to_entries):
        to_index = len(to_entries)

    if from_region == to_region and from_index == to_index:
        from_entries.insert(from_index, moved)
        return False

    to_entries.insert(to_index, moved)
    return True


class BarDragTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "bar": {
                "layout": {
                    "left": ["omarchy.menu", "omarchy.workspaces"],
                    "center": ["omarchy.indicators", "omarchy.clock"],
                    "right": ["omarchy.tray", "omarchy.bluetooth", "omarchy.power"]
                }
            }
        }

    def test_reorder_within_same_region_forward(self):
        # Move menu after workspaces
        res = move_module_in_config(self.config, "left", "omarchy.menu", "left", "")
        self.assertTrue(res)
        self.assertEqual(self.config["bar"]["layout"]["left"], ["omarchy.workspaces", "omarchy.menu"])

    def test_reorder_within_same_region_backward(self):
        # Move workspaces before menu
        res = move_module_in_config(self.config, "left", "omarchy.workspaces", "left", "omarchy.menu")
        self.assertTrue(res)
        self.assertEqual(self.config["bar"]["layout"]["left"], ["omarchy.workspaces", "omarchy.menu"])

    def test_move_across_regions_before_target(self):
        # Move tray from right to left before workspaces
        res = move_module_in_config(self.config, "right", "omarchy.tray", "left", "omarchy.workspaces")
        self.assertTrue(res)
        self.assertEqual(self.config["bar"]["layout"]["left"], ["omarchy.menu", "omarchy.tray", "omarchy.workspaces"])
        self.assertEqual(self.config["bar"]["layout"]["right"], ["omarchy.bluetooth", "omarchy.power"])

    def test_move_across_regions_to_end(self):
        # Move clock from center to end of right
        res = move_module_in_config(self.config, "center", "omarchy.clock", "right", "")
        self.assertTrue(res)
        self.assertEqual(self.config["bar"]["layout"]["center"], ["omarchy.indicators"])
        self.assertEqual(self.config["bar"]["layout"]["right"], ["omarchy.tray", "omarchy.bluetooth", "omarchy.power", "omarchy.clock"])

    def test_move_to_empty_region(self):
        self.config["bar"]["layout"]["left"] = []
        res = move_module_in_config(self.config, "right", "omarchy.power", "left", "")
        self.assertTrue(res)
        self.assertEqual(self.config["bar"]["layout"]["left"], ["omarchy.power"])
        self.assertEqual(self.config["bar"]["layout"]["right"], ["omarchy.tray", "omarchy.bluetooth"])

    def test_no_op_reorder_to_same_position(self):
        res = move_module_in_config(self.config, "left", "omarchy.menu", "left", "omarchy.menu")
        self.assertFalse(res)
        self.assertEqual(self.config["bar"]["layout"]["left"], ["omarchy.menu", "omarchy.workspaces"])

    def test_nonexistent_module_returns_false(self):
        res = move_module_in_config(self.config, "left", "nonexistent", "right", "")
        self.assertFalse(res)


if __name__ == '__main__':
    unittest.main()
