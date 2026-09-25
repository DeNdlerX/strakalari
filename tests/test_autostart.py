from strakalari.core.autostart import get_launch_command


class TestAutostart:
    def test_get_launch_command_minimized(self):
        cmd = get_launch_command(minimized=True)
        assert "--minimized" in cmd

    def test_get_launch_command_not_minimized(self):
        cmd = get_launch_command(minimized=False)
        assert "--minimized" not in cmd


class TestRoutingAndLaunch:
    def test_launch_command_has_no_shell_quotes(self):
        from strakalari.core.autostart import get_launch_command
        cmd = get_launch_command(minimized=True)
        assert "--minimized" in cmd
        assert "'" not in cmd
