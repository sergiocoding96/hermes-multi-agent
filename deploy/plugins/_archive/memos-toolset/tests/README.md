# memos-toolset tests

The plugin folder name contains a hyphen, which makes pytest's default
discovery walk fail (the plugin's own `__init__.py` is not a test module
but pytest tries to import it as one). Run from inside this directory:

```bash
cd deploy/plugins/_archive/memos-toolset/tests
pytest test_auto_capture.py -v --rootdir=.
```

Or, equivalently, from the repo root:

```bash
pytest deploy/plugins/_archive/memos-toolset/tests/test_auto_capture.py \
    --rootdir=deploy/plugins/_archive/memos-toolset/tests -v
```

No real MemOS server is needed — `_fake_server.FakeMemOSServer` stands in
on a free localhost port.
