"""Import-time stubs installed before mlx_audio is imported.

sounddevice: mlx-audio lists it as a dependency for its audio player. Importing the real module
loads PortAudio, which initialises Core Audio and gives the engine a Core Audio process object;
the engine must never be an audio client (M0-T0). The lock does not install sounddevice at all,
and this stub makes any accidental import fail loudly instead of silently opening devices.
"""
import sys
import types


class _SoundDeviceStub(types.ModuleType):
    __talktalk_stub__ = True

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        raise RuntimeError("sounddevice is stubbed in talktalk-engine (the engine never opens audio devices)")


def install():
    stub = _SoundDeviceStub("sounddevice")
    stub.__file__ = "<talktalk-engine stub>"
    sys.modules["sounddevice"] = stub
    return stub


def is_installed():
    return getattr(sys.modules.get("sounddevice"), "__talktalk_stub__", False) is True
