#!/usr/bin/env python3
"""Exercise result reporting through fake Xcode tools, without simulator/UI/audio activity."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name('ui-tests.sh')
TOOL = '''#!/usr/bin/env python3
import json,os,pathlib,sys
config=json.loads(pathlib.Path(os.environ['UI_RUNNER_FIXTURE']).read_text())
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if name=='xcodegen' or (name=='xcrun' and args[0]=='simctl'): sys.exit(0)
if name=='xcodebuild':
 if args[0]=='build-for-testing': sys.exit(0)
 pathlib.Path(config['argv']).write_text(json.dumps(args))
 bundle=pathlib.Path(args[args.index('-resultBundlePath')+1]);bundle.mkdir(parents=True)
 (bundle/'attachment.txt').write_text('fixture attachment retained')
 print('NativeUI.swift:1: error: fixture assertion failed' if config['failed'] else 'fixture tests finished')
 sys.exit(config['xcodeRC'])
if name=='xcrun' and args[:4]==['xcresulttool','get','test-results','summary']:
 print(config['summary'])
 if config['summaryRC']: print('fixture bundle is unfinished',file=sys.stderr)
 sys.exit(config['summaryRC'])
raise SystemExit('unexpected fixture tool call')
'''

class UITestRunnerTests(unittest.TestCase):
    def run_fixture(self, summary=None, *, summary_rc=0, xcode_rc=0, raw=None):
        with tempfile.TemporaryDirectory(prefix='baton-ui-reporting-') as folder:
            root = Path(folder)
            tools = root/'bin'; tools.mkdir()
            for name in ('xcodebuild', 'xcrun', 'xcodegen'):
                path=tools/name; path.write_text(TOOL); path.chmod(0o700)
            fixtures=root/'fixture.json'
            fixtures.write_text(json.dumps({'summary': raw if raw is not None else json.dumps(summary),
                'summaryRC':summary_rc,'xcodeRC':xcode_rc,'failed':bool((summary or {}).get('failedTests')),
                'argv':str(root/'argv.json')}))
            env={'PATH':str(tools)+os.pathsep+str(Path(sys.executable).parent)+':/usr/bin:/bin',
                 'TMPDIR':str(root),'UI_RUNNER_FIXTURE':str(fixtures),'UITEST_SIM':'synthetic-simulator',
                 'UITEST_DD':str(root/'dd'),'UITEST_RESULTS':str(root/'results'),
                 'UITEST_BUILD_LOG':str(root/'build.log')}
            result=subprocess.run(['/bin/bash',str(RUNNER),'-only','SuiteA, SuiteB'],env=env,
                                  text=True,capture_output=True,timeout=15)
            args=json.loads((root/'argv.json').read_text())
            self.assertEqual(args[args.index('-collect-test-diagnostics')+1],'never')
            self.assertEqual([arg for arg in args if arg.startswith('-only-testing:')],
                             ['-only-testing:SuiteA','-only-testing:SuiteB'])
            self.assertFalse(any(arg.startswith('-skip-testing:') for arg in args))
            self.assertTrue((root/'results/ui.xcresult/attachment.txt').is_file())
            return result.returncode,result.stdout+result.stderr

    def test_readable_success_keeps_all_counts(self):
        code,output=self.run_fixture({'passedTests':7,'failedTests':0,'skippedTests':4})
        self.assertEqual(code,0);self.assertIn('7 passed, 0 failed, 4 skipped',output)

    def test_readable_failure_keeps_actual_failures(self):
        code,output=self.run_fixture({'passedTests':7,'failedTests':4,'skippedTests':0},xcode_rc=65)
        self.assertEqual(code,1);self.assertIn('7 passed, 4 failed, 0 skipped',output)

    def test_readable_all_skipped_still_fails(self):
        code,output=self.run_fixture({'passedTests':0,'failedTests':0,'skippedTests':11})
        self.assertEqual(code,1);self.assertIn('every UI test skipped',output)

    def assert_unavailable(self, *, expected=1, **kwargs):
        code,output=self.run_fixture(**kwargs)
        self.assertEqual(code,expected);self.assertIn('counts unavailable',output)
        self.assertNotIn('0 passed, 0 failed, 0 skipped',output)
        self.assertNotIn('every UI test skipped',output)
        self.assertIn('result bundle:',output);self.assertIn('run log:',output)
        self.assertIn('summary diagnostics:',output)

    def test_unreadable_bundle_preserves_interrupted_xcode_exit(self):
        self.assert_unavailable(summary={},summary_rc=1,xcode_rc=143,expected=143)

    def test_unreadable_bundle_fails_even_if_xcode_says_success(self):
        self.assert_unavailable(summary={},summary_rc=1)

    def test_malformed_json_is_unavailable(self):
        self.assert_unavailable(raw='{unfinished')

    def test_missing_required_count_is_unavailable(self):
        self.assert_unavailable(summary={'passedTests':7,'skippedTests':0})

    def test_invalid_count_types_are_unavailable(self):
        for invalid in (-1,True,1.5,'7',None):
            with self.subTest(invalid=invalid):
                self.assert_unavailable(summary={'passedTests':invalid,'failedTests':0,'skippedTests':0})

if __name__=='__main__': unittest.main()
