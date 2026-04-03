import UIKit

enum KeySymMapping {

    /// Convert a UIKey to an X11 keysym for the RFB KeyEvent message.
    static func keysym(for key: UIKey) -> UInt32? {
        // Check modifier keys first
        if let modKeysym = modifierKeysym(for: key.keyCode) {
            return modKeysym
        }

        // Check special non-printable keys
        if let specialKeysym = specialKeysym(for: key.keyCode) {
            return specialKeysym
        }

        // For printable characters, use the character value
        // X11 keysyms for Latin-1 (0x20-0x7E) match Unicode code points
        let chars = key.characters
        if let scalar = chars.unicodeScalars.first {
            let codePoint = scalar.value
            if codePoint >= 0x20 && codePoint <= 0x7E {
                return codePoint
            }
            // Latin-1 supplement (0xA0-0xFF) also maps directly
            if codePoint >= 0xA0 && codePoint <= 0xFF {
                return codePoint
            }
        }

        return nil
    }

    // MARK: - Modifier Keys

    private static func modifierKeysym(for keyCode: UIKeyboardHIDUsage) -> UInt32? {
        switch keyCode {
        case .keyboardLeftShift:     return 0xFFE1 // XK_Shift_L
        case .keyboardRightShift:    return 0xFFE2 // XK_Shift_R
        case .keyboardLeftControl:   return 0xFFE3 // XK_Control_L
        case .keyboardRightControl:  return 0xFFE4 // XK_Control_R
        case .keyboardLeftAlt:       return 0xFFE9 // XK_Alt_L
        case .keyboardRightAlt:      return 0xFFEA // XK_Alt_R
        case .keyboardLeftGUI:       return 0xFFEB // XK_Super_L (Cmd)
        case .keyboardRightGUI:      return 0xFFEC // XK_Super_R
        case .keyboardCapsLock:      return 0xFFE5 // XK_Caps_Lock
        default: return nil
        }
    }

    // MARK: - Special Keys

    private static func specialKeysym(for keyCode: UIKeyboardHIDUsage) -> UInt32? {
        switch keyCode {
        case .keyboardReturnOrEnter:     return 0xFF0D // XK_Return
        case .keyboardEscape:            return 0xFF1B // XK_Escape
        case .keyboardDeleteOrBackspace: return 0xFF08 // XK_BackSpace
        case .keyboardTab:               return 0xFF09 // XK_Tab
        case .keyboardSpacebar:          return 0x0020 // XK_space
        case .keyboardDeleteForward:     return 0xFFFF // XK_Delete
        case .keyboardInsert:            return 0xFF63 // XK_Insert
        case .keyboardHome:              return 0xFF50 // XK_Home
        case .keyboardEnd:               return 0xFF57 // XK_End
        case .keyboardPageUp:            return 0xFF55 // XK_Page_Up
        case .keyboardPageDown:          return 0xFF56 // XK_Page_Down
        case .keyboardRightArrow:        return 0xFF53 // XK_Right
        case .keyboardLeftArrow:         return 0xFF51 // XK_Left
        case .keyboardDownArrow:         return 0xFF54 // XK_Down
        case .keyboardUpArrow:           return 0xFF52 // XK_Up
        case .keyboardF1:                return 0xFFBE // XK_F1
        case .keyboardF2:                return 0xFFBF // XK_F2
        case .keyboardF3:                return 0xFFC0 // XK_F3
        case .keyboardF4:                return 0xFFC1 // XK_F4
        case .keyboardF5:                return 0xFFC2 // XK_F5
        case .keyboardF6:                return 0xFFC3 // XK_F6
        case .keyboardF7:                return 0xFFC4 // XK_F7
        case .keyboardF8:                return 0xFFC5 // XK_F8
        case .keyboardF9:                return 0xFFC6 // XK_F9
        case .keyboardF10:               return 0xFFC7 // XK_F10
        case .keyboardF11:               return 0xFFC8 // XK_F11
        case .keyboardF12:               return 0xFFC9 // XK_F12
        case .keyboardPrintScreen:       return 0xFF61 // XK_Print
        case .keyboardScrollLock:        return 0xFF14 // XK_Scroll_Lock
        case .keyboardPause:             return 0xFF13 // XK_Pause
        // Keypad
        case .keypadNumLock:             return 0xFF7F // XK_Num_Lock
        case .keypadSlash:               return 0xFFAF // XK_KP_Divide
        case .keypadAsterisk:            return 0xFFAA // XK_KP_Multiply
        case .keypadHyphen:              return 0xFFAD // XK_KP_Subtract
        case .keypadPlus:                return 0xFFAB // XK_KP_Add
        case .keypadEnter:               return 0xFF8D // XK_KP_Enter
        case .keypad0:                   return 0xFFB0 // XK_KP_0
        case .keypad1:                   return 0xFFB1 // XK_KP_1
        case .keypad2:                   return 0xFFB2 // XK_KP_2
        case .keypad3:                   return 0xFFB3 // XK_KP_3
        case .keypad4:                   return 0xFFB4 // XK_KP_4
        case .keypad5:                   return 0xFFB5 // XK_KP_5
        case .keypad6:                   return 0xFFB6 // XK_KP_6
        case .keypad7:                   return 0xFFB7 // XK_KP_7
        case .keypad8:                   return 0xFFB8 // XK_KP_8
        case .keypad9:                   return 0xFFB9 // XK_KP_9
        case .keypadPeriod:              return 0xFFAE // XK_KP_Decimal
        default: return nil
        }
    }
}
