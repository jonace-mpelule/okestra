import importlib.util
import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('android_tools',Path(__file__).with_name('android-tools.py'))
tools=importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)

class ToolSetupTests(unittest.TestCase):
    def test_device_only_setup_skips_flutter_and_node(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            sdkmanager=root/'android-sdk/cmdline-tools/latest/bin/sdkmanager'
            sdkmanager.parent.mkdir(parents=True)
            sdkmanager.write_text('installed')
            with patch.object(tools,'ROOT',root), patch.object(tools.os,'geteuid',return_value=1000), patch.object(tools.sys,'argv',['android-tools.py','--sdk-only']), patch.object(tools,'install_node') as node, patch.object(tools,'fetch') as download:
                tools.install()
            node.assert_not_called()
            download.assert_not_called()
            self.assertFalse((root/'flutter').exists())
    def test_official_flutter_manifest_endpoint(self):
        self.assertEqual(tools.FLUTTER_RELEASES_URL,'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json')
    def test_node_lts_selection(self):
        metadata=[{'version':'v25.0.0','lts':False,'files':['linux-x64']},{'version':'v24.10.0','lts':'LTS','files':['linux-x64']}]
        self.assertEqual(tools.node_release(metadata),('v24.10.0','node-v24.10.0-linux-x64.tar.xz'))
        with self.assertRaises(RuntimeError):tools.node_release([{'version':'../invalid','lts':True,'files':['linux-x64']}])

    def test_flutter_selects_x64_and_rejects_untrusted_paths(self):
        metadata={'current_release':{'stable':'abc'},'releases':[{'hash':'abc','dart_sdk_arch':'arm64','archive':'stable/linux/arm.tar.xz','sha256':'no'},{'hash':'abc','dart_sdk_arch':'x64','archive':'stable/linux/x64.tar.xz','sha256':'yes'}]}
        self.assertEqual(tools.stable_flutter(metadata)[1],'yes')
        metadata['releases'][1]['archive']='../evil'
        with self.assertRaises(RuntimeError):tools.stable_flutter(metadata)
    def test_sdk_selects_stable_linux_archive(self):
        fixture='''<repository xmlns="urn:android"><remotePackage path="cmdline-tools;19.0"><revision><major>19</major></revision><channelRef ref="channel-0"/><archives><archive><host-os>linux</host-os><complete><url>commandlinetools-linux-123_latest.zip</url><checksum type="sha256">expected</checksum></complete></archive></archives></remotePackage></repository>'''
        self.assertEqual(tools.command_tools(fixture),('https://dl.google.com/android/repository/commandlinetools-linux-123_latest.zip','sha256','expected'))
        with self.assertRaises(RuntimeError):tools.command_tools(fixture.replace('channel-0','channel-1'))
    def test_checksum_and_zip_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);archive=root/'tools.zip';archive.write_bytes(b'valid')
            tools.verify(archive,'sha256',hashlib.sha256(b'valid').hexdigest())
            with self.assertRaises(RuntimeError):tools.verify(archive,'sha256','wrong')
            with zipfile.ZipFile(archive,'w') as f:f.writestr('../escape','bad')
            with self.assertRaises(RuntimeError):tools.unzip_checked(archive,root/'extract')
            self.assertFalse((root/'escape').exists())

if __name__=='__main__':unittest.main()
