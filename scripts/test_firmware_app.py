import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("firmware_app",Path(__file__).with_name("firmware-app.py"))
app=importlib.util.module_from_spec(spec);spec.loader.exec_module(app)

class FirmwareWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.local=self.root/".local"
        (self.local/"venv/bin").mkdir(parents=True);(self.local/"venv/bin/python").touch()
        self.request=dict(action="build",displayID="desk",serverURL="http://server:8099",deviceToken="private-token",ssid="test $(literal)",password="password-123",port="/dev/cu.usbmodemTEST")
        self.calls=[]
        self.bad_partition=False
        self.fail=False
        self.table=struct.pack("<HBBII16sI",0x50aa,0,0,0x10000,0x300000,b"app",0)+bytes([255])*32
    def fake(self,command,**kwargs):
        self.calls.append(command)
        for secret in [self.request['password'],self.request['deviceToken'],self.request['ssid']]:
            self.assertFalse(any(secret in str(arg) for arg in command))
        if "scripts/build-firmware.py" in command:
            output=self.local/"firmware"/command[command.index("--output")+1]
            output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(b"firmware-test")
        if "read-flash" in command:
            destination=Path(command[-1])
            destination.write_bytes((b"invalid" if self.bad_partition else self.table) if command[-3]=="0x8000" else bytes(0x400000))
        text="MAC: aa:bb:cc:dd:ee:ff" if "read-mac" in command else "Complete"
        if self.fail:text=self.request['password']+self.request['deviceToken']
        return subprocess.CompletedProcess(command,1 if self.fail else 0,text)
    def invoke(self,request=None):
        output=io.StringIO()
        self.captured=output
        with patch.object(app,"ROOT",self.root),patch.object(app,"LOCAL",self.local),patch.object(app.sys,"stdin",io.StringIO(json.dumps(request or self.request))),patch.object(app.subprocess,"run",self.fake),contextlib.redirect_stdout(output):
            app.main()
        return output.getvalue()
    def test_build_private_manifest_and_transient_cleanup(self):
        self.invoke()
        manifest=json.loads((self.local/"firmware/maclink-desk.json").read_text())
        self.assertEqual(manifest['fingerprint'],app.fingerprint(self.request))
        self.assertEqual((self.local/"device-desk.json").stat().st_mode & 0o777,0o600)
        self.assertFalse((self.local/"wifi-build-desk.json").exists())
        self.assertEqual(json.loads((self.local/"device-desk.json").read_text())['id'],'desk')
    def test_changed_credentials_or_corrupt_image_cannot_flash(self):
        self.invoke();self.request['action']='flash';self.request['password']='different-password'
        with self.assertRaisesRegex(ValueError,'changed'):self.invoke()
        self.request['password']='password-123';(self.local/"firmware/maclink-desk.bin").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError,'changed'):self.invoke()
        self.assertFalse(any('write-flash' in call for call in self.calls))
    def test_other_display_cannot_use_build(self):
        self.invoke();self.request.update(action='flash',displayID='other')
        with self.assertRaisesRegex(ValueError,'Build firmware'):self.invoke()
    def test_invalid_wifi_and_port_rejected(self):
        for key,value in [('ssid',''),('password','short')]:
            bad=dict(self.request);bad[key]=value
            with self.assertRaises(ValueError):app.validate(bad)
        self.invoke();self.request.update(action='flash',port='/tmp/arbitrary-file')
        with self.assertRaisesRegex(ValueError,'USB serial'):self.invoke()
    def test_partition_gate_and_backup_before_flash(self):
        self.invoke();self.request['action']='flash'
        # Only the virtual port is faked; real artifact existence checks still run.
        original=Path.exists
        with patch.object(Path,'exists',lambda path: True if str(path)==self.request['port'] else original(path)):
            self.bad_partition=True
            with self.assertRaisesRegex(ValueError,'partition layout'):self.invoke()
            self.assertFalse(any('write-flash' in call for call in self.calls))
            self.bad_partition=False;self.invoke()
        backup=self.local/'firmware/backups/aabbccddeeff/before-maclink.bin'
        self.assertEqual(backup.stat().st_size,0x400000)
        self.assertEqual(backup.with_suffix('.sha256').read_text(),hashlib.sha256(backup.read_bytes()).hexdigest())
        writes=[call for call in self.calls if 'write-flash' in call]
        self.assertEqual(len(writes),1);self.assertEqual(writes[0][-2],'0x10000')
    def test_errors_do_not_expose_credentials(self):
        self.fail=True;output=io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(ValueError):self.invoke()
        self.assertNotIn(self.request['password'],self.captured.getvalue())
        self.assertNotIn(self.request['deviceToken'],self.captured.getvalue())
        self.assertIn('[private]',self.captured.getvalue())
        self.assertFalse((self.local/'wifi-build-desk.json').exists())

if __name__=='__main__':unittest.main()
