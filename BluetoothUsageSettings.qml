import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "bluetoothUsage"

    ToggleSetting {
        settingKey: "trackAllDevices"
        label: "Track all Bluetooth devices"
        description: "Off tracks only headsets and speakers (recommended for TWS earbuds). On also records keyboards, mice, phones and everything else."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showBattery"
        label: "Show battery percentage in the bar"
        description: "Uses the battery level reported by BlueZ. Not every headset exposes it."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "hideWhenIdle"
        label: "Hide the bar widget while disconnected"
        description: "When off, the widget shows today's total instead."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notifyOnConnect"
        label: "Notify when a device connects"
        description: "Shows a DMS toast when a tracked session starts."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notifyOnDisconnect"
        label: "Notify when a device disconnects"
        description: "Shows a DMS toast with the duration of the finished session."
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "graceSeconds"
        label: "Reconnect grace period"
        description: "Short dropouts (for example while a headset switches between A2DP and hands-free) shorter than this are merged into the same session."
        options: [
            { label: "15 seconds", value: "15" },
            { label: "30 seconds", value: "30" },
            { label: "45 seconds", value: "45" },
            { label: "90 seconds", value: "90" },
            { label: "3 minutes", value: "180" }
        ]
        defaultValue: "45"
    }

    StyledText {
        width: parent.width
        text: "Data"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Theme.fontWeightMedium
        color: Theme.surfaceText
        topPadding: Theme.spacingS
    }

    StyledText {
        width: parent.width
        text: "Sessions are stored locally in ~/.local/state/dms/bluetooth-usage.json. The file survives shell restarts and records at most three months of daily history and the last 60 sessions per device."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DButton {
        text: "Clear all statistics"
        iconName: "delete"
        danger: true
        variant: "tonal"
        onClicked: {
            root.saveValue("resetAt", Date.now());
        }
    }
}
