from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCHEMES = ROOT / "Glimt.xcodeproj" / "xcshareddata" / "xcschemes"
# Xcode refuses to run a scheme whose debugger it does not know ("Unable to launch executable")
# and starts no build, so an unknown identifier only shows up when someone presses Run.
KNOWN_DEBUGGERS = {"", "Xcode.DebuggerFoundation.Debugger.LLDB"}
KNOWN_LAUNCHERS = {"Xcode.DebuggerFoundation.Launcher.LLDB", "Xcode.IDEFoundation.Launcher.PosixSpawn"}


class XcodeSchemeTests(unittest.TestCase):
    def test_shared_schemes_name_debuggers_and_launchers_xcode_knows(self):
        schemes = sorted(SCHEMES.glob("*.xcscheme"))
        self.assertTrue(schemes)
        for scheme in schemes:
            text = scheme.read_text()
            for debugger in re.findall(r'selectedDebuggerIdentifier = "([^"]*)"', text):
                self.assertIn(debugger, KNOWN_DEBUGGERS, scheme.name)
            for launcher in re.findall(r'selectedLauncherIdentifier = "([^"]*)"', text):
                self.assertIn(launcher, KNOWN_LAUNCHERS, scheme.name)


if __name__ == "__main__":
    unittest.main()
