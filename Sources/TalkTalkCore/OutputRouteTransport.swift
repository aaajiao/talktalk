extension OutputRouteClassifier.Transport {
    /// From `kAudioDevicePropertyTransportType` as a four-char string (InputDeviceCatalog.fourCC):
    /// 'bltn', 'usb ', 'blue', 'blea', 'hdmi', 'dprt', 'airp', 'thun', 'pci ', '1394', 'virt',
    /// 'grup' / 'fgrp' (aggregate, auto-aggregate). `.unknown` is only "the HAL reports no
    /// transport" (code 0, which fourCC prints as "0x00000000"; the empty string too): the one case
    /// where a device named External Headphones counts as headphones. Every other code the
    /// classifier has no case for (AVB, Continuity Capture, remote screen / streaming, codes added
    /// later) is `.virtual`, always a speaker: §3.7 "其余一律算外放".
    public init(fourCC: String) {
        switch fourCC {
        case "bltn": self = .builtIn
        case "usb ": self = .usb
        case "blue": self = .bluetooth
        case "blea": self = .bluetoothLE
        case "hdmi": self = .hdmi
        case "dprt": self = .displayPort
        case "airp": self = .airPlay
        case "thun": self = .thunderbolt
        case "pci ": self = .pci
        case "1394": self = .firewire
        case "virt": self = .virtual
        case "grup", "fgrp": self = .aggregate
        case "0x00000000", "": self = .unknown
        default: self = .virtual
        }
    }
}
