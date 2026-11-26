import CoreGraphics

/// Ports of popular themes, in their original colors. Each comes from the theme's official
/// tree-sitter port for Neovim where there is one, so highlights match one to one: Catppuccin
/// (catppuccin/nvim), Dracula and Alucard (dracula/vim), GitHub (primer/github-vscode-theme),
/// Gruvbox (ellisonleao/gruvbox.nvim), Nord (nordtheme/vim), One Dark and One Light (Atom),
/// Rosé Pine (rose-pine/neovim), Solarized (altercation/vim-colors-solarized) and Tokyo Night
/// (folke/tokyonight.nvim). Where an original leaves a kind of highlight to the editor's
/// defaults, it gets what those defaults give it; where it leaves punctuation or parameters
/// uncolored, they're the text color. Search matches are drawn translucent, since Vie keeps
/// the syntax colors on them. Licenses: App/ThemeLicenses.txt.
extension EditorTheme {
    static let ports: [EditorTheme] = [
        alucard, catppuccinLatte, catppuccinFrappe, catppuccinMacchiato, catppuccinMocha, dracula,
        githubLight, githubDark, gruvboxLight, gruvboxDark, nord, oneLight, oneDark,
        rosePine, rosePineMoon, rosePineDawn, solarizedLight, solarizedDark,
        tokyoNight, tokyoNightStorm, tokyoNightMoon, tokyoNightDay,
    ]

    // MARK: Catppuccin

    static let catppuccinLatte = catppuccin("Catppuccin Latte", dark: false, base: 0xEFF1F5, currentLine: 0xE9EBF1,
        text: 0x4C4F69, surface1: 0xBCC0CC, overlay2: 0x7C7F93, rosewater: 0xDC8A78, search: 0xA9DAF0,
        mauve: 0x8839EF, red: 0xD20F39, maroon: 0xE64553, peach: 0xFE640B, yellow: 0xDF8E1D, green: 0x40A02B,
        pink: 0xEA76CB, sky: 0x04A5E5, sapphire: 0x209FB5, blue: 0x1E66F5, lavender: 0x7287FD)

    static let catppuccinFrappe = catppuccin("Catppuccin Frappé", dark: true, base: 0x303446, currentLine: 0x3B3F52,
        text: 0xC6D0F5, surface1: 0x51576D, overlay2: 0x949CBB, rosewater: 0xF2D5CF, search: 0x506373,
        mauve: 0xCA9EE6, red: 0xE78284, maroon: 0xEA999C, peach: 0xEF9F76, yellow: 0xE5C890, green: 0xA6D189,
        pink: 0xF4B8E4, sky: 0x99D1DB, sapphire: 0x85C1DC, blue: 0x8CAAEE, lavender: 0xBABBF1)

    static let catppuccinMacchiato = catppuccin("Catppuccin Macchiato", dark: true, base: 0x24273A, currentLine: 0x303347,
        text: 0xCAD3F5, surface1: 0x494D64, overlay2: 0x939AB7, rosewater: 0xF4DBD6, search: 0x455C6D,
        mauve: 0xC6A0F6, red: 0xED8796, maroon: 0xEE99A0, peach: 0xF5A97F, yellow: 0xEED49F, green: 0xA6DA95,
        pink: 0xF5BDE6, sky: 0x91D7E3, sapphire: 0x7DC4E4, blue: 0x8AADF4, lavender: 0xB7BDF8)

    static let catppuccinMocha = catppuccin("Catppuccin Mocha", dark: true, base: 0x1E1E2E, currentLine: 0x2A2B3C,
        text: 0xCDD6F4, surface1: 0x45475A, overlay2: 0x9399B2, rosewater: 0xF5E0DC, search: 0x3E5767,
        mauve: 0xCBA6F7, red: 0xF38BA8, maroon: 0xEBA0AC, peach: 0xFAB387, yellow: 0xF9E2AF, green: 0xA6E3A1,
        pink: 0xF5C2E7, sky: 0x89DCEB, sapphire: 0x74C7EC, blue: 0x89B4FA, lavender: 0xB4BEFE)

    /// The flavors share one mapping (catppuccin/nvim's editor and tree-sitter groups).
    private static func catppuccin(_ name: String, dark: Bool, base: UInt32, currentLine: UInt32, text: UInt32,
                                   surface1: UInt32, overlay2: UInt32, rosewater: UInt32, search: UInt32,
                                   mauve: UInt32, red: UInt32, maroon: UInt32, peach: UInt32, yellow: UInt32,
                                   green: UInt32, pink: UInt32, sky: UInt32, sapphire: UInt32, blue: UInt32,
                                   lavender: UInt32) -> EditorTheme {
        EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(base), currentLine: hex(currentLine), text: hex(text), lineNumber: hex(surface1),
            cursor: hex(rosewater), selection: hex(surface1), search: hex(search), currentSearch: hex(red, dark ? 0.45 : 0.35),
            error: hex(red),
            syntax: Syntax(
                comment: ink(overlay2).italic, keyword: ink(mauve), string: ink(green), escape: ink(pink),
                builtinFunction: ink(peach), label: ink(sapphire), link: ink(blue).italic,
                number: ink(peach), constant: ink(peach), boolean: ink(peach), builtinConstant: ink(peach), attribute: ink(peach),
                function: ink(blue), type: ink(yellow), builtinType: ink(mauve), module: ink(yellow).italic,
                builtinVariable: ink(red), property: ink(lavender), tag: ink(blue), parameter: ink(maroon),
                operator: ink(sky), punctuation: ink(overlay2), bracket: ink(overlay2), heading: ink(blue))))
    }

    // MARK: Dracula

    static let dracula = draculaTheme("Dracula", dark: true, background: 0x282A36, currentLine: 0x424450, foreground: 0xF8F8F2,
        comment: 0x6272A4, selection: 0x44475A, red: 0xFF5555, orange: 0xFFB86C, yellow: 0xF1FA8C, green: 0x50FA7B,
        cyan: 0x8BE9FD, purple: 0xBD93F9, pink: 0xFF79C6)

    /// Dracula's light theme, from the Dracula spec's palette.
    static let alucard = draculaTheme("Alucard", dark: false, background: 0xFFFBEB, currentLine: 0xE2DECA, foreground: 0x1F1F1F,
        comment: 0x6C664B, selection: 0xCFCFDE, red: 0xCB3A2A, orange: 0xA34D14, yellow: 0x846E15, green: 0x14710A,
        cyan: 0x036A96, purple: 0x644AC9, pink: 0xA3144D)

    /// dracula/vim's assignments (which match the Dracula VS Code theme), for both palettes.
    private static func draculaTheme(_ name: String, dark: Bool, background: UInt32, currentLine: UInt32,
                                     foreground: UInt32, comment: UInt32, selection: UInt32, red: UInt32, orange: UInt32,
                                     yellow: UInt32, green: UInt32, cyan: UInt32, purple: UInt32, pink: UInt32) -> EditorTheme {
        EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(background), currentLine: hex(currentLine), text: hex(foreground),
            lineNumber: hex(comment), cursor: hex(foreground), selection: hex(selection),
            search: hex(green, dark ? 0.3 : 0.2), currentSearch: hex(orange, dark ? 0.5 : 0.3), error: hex(red),
            syntax: .dracula(foreground: foreground, comment: comment, orange: orange, yellow: yellow, green: green,
                             cyan: cyan, purple: purple, pink: pink)))
    }

    // MARK: GitHub

    /// GitHub Light Default.
    static let githubLight = EditorTheme(name: "GitHub Light", isDark: false, palette: Palette(
        dark: false, background: hex(0xFFFFFF), currentLine: hex(0xEAEEF2, 0.5), text: hex(0x1F2328), lineNumber: hex(0x8C959F),
        cursor: hex(0x0969DA), selection: hex(0x0969DA, 0.2), search: hex(0xFAE17D, 0.5), currentSearch: hex(0x9A6700, 0.4),
        error: hex(0xD1242F),
        syntax: Syntax(
            comment: ink(0x6E7781), keyword: ink(0xCF222E), string: ink(0x0A3069), escape: ink(0xCF222E),
            builtinFunction: ink(0x0550AE), label: ink(0x953800), link: ink(0x0A3069),
            number: ink(0x0550AE), constant: ink(0x0550AE), boolean: ink(0x0550AE), builtinConstant: ink(0x0550AE),
            attribute: ink(0x8250DF), function: ink(0x8250DF), type: ink(0x953800), builtinType: ink(0xCF222E),
            module: ink(0x953800), builtinVariable: ink(0x0550AE), property: ink(0x0550AE), tag: ink(0x116329),
            parameter: ink(0x953800), operator: ink(0xCF222E), punctuation: ink(0x1F2328), bracket: ink(0x1F2328),
            heading: ink(0x0550AE).bold)))

    /// GitHub Dark Default.
    static let githubDark = EditorTheme(name: "GitHub Dark", isDark: true, palette: Palette(
        dark: true, background: hex(0x0D1117), currentLine: hex(0x6E7681, 0.1), text: hex(0xE6EDF3), lineNumber: hex(0x6E7681),
        cursor: hex(0x2F81F7), selection: hex(0x2F81F7, 0.2), search: hex(0xF2CC60, 0.5), currentSearch: hex(0x9E6A03, 0.6),
        error: hex(0xF85149),
        syntax: Syntax(
            comment: ink(0x8B949E), keyword: ink(0xFF7B72), string: ink(0xA5D6FF), escape: ink(0xFF7B72),
            builtinFunction: ink(0x79C0FF), label: ink(0xFFA657), link: ink(0xA5D6FF),
            number: ink(0x79C0FF), constant: ink(0x79C0FF), boolean: ink(0x79C0FF), builtinConstant: ink(0x79C0FF),
            attribute: ink(0xD2A8FF), function: ink(0xD2A8FF), type: ink(0xFFA657), builtinType: ink(0xFF7B72),
            module: ink(0xFFA657), builtinVariable: ink(0x79C0FF), property: ink(0x79C0FF), tag: ink(0x7EE787),
            parameter: ink(0xFFA657), operator: ink(0xFF7B72), punctuation: ink(0xE6EDF3), bracket: ink(0xE6EDF3),
            heading: ink(0x79C0FF).bold)))

    // MARK: Gruvbox (medium contrast)

    static let gruvboxDark = gruvbox("Gruvbox Dark", dark: true, bg0: 0x282828, bg1: 0x3C3836, bg3: 0x665C54, bg4: 0x7C6F64,
        fg1: 0xEBDBB2, red: 0xFB4934, green: 0xB8BB26, yellow: 0xFABD2F, blue: 0x83A598, purple: 0xD3869B,
        aqua: 0x8EC07C, orange: 0xFE8019)

    static let gruvboxLight = gruvbox("Gruvbox Light", dark: false, bg0: 0xFBF1C7, bg1: 0xEBDBB2, bg3: 0xBDAE93, bg4: 0xA89984,
        fg1: 0x3C3836, red: 0x9D0006, green: 0x79740E, yellow: 0xB57614, blue: 0x076678, purple: 0x8F3F71,
        aqua: 0x427B58, orange: 0xAF3A03)

    /// gruvbox.nvim's groups at its defaults (italic comments and strings, bold functions).
    private static func gruvbox(_ name: String, dark: Bool, bg0: UInt32, bg1: UInt32, bg3: UInt32, bg4: UInt32, fg1: UInt32,
                                red: UInt32, green: UInt32, yellow: UInt32, blue: UInt32, purple: UInt32, aqua: UInt32,
                                orange: UInt32) -> EditorTheme {
        EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(bg0), currentLine: hex(bg1), text: hex(fg1), lineNumber: hex(bg4), cursor: hex(fg1),
            selection: hex(bg3), search: hex(yellow, dark ? 0.35 : 0.3), currentSearch: hex(orange, dark ? 0.5 : 0.35),
            error: hex(red),
            syntax: Syntax(
                comment: Ink(color: hex(0x928374)).italic, keyword: ink(red), string: ink(green).italic, escape: ink(orange),
                builtinFunction: ink(orange), label: ink(red), link: ink(blue),
                number: ink(purple), constant: ink(purple), boolean: ink(purple), builtinConstant: ink(orange),
                attribute: ink(aqua), function: ink(green).bold, type: ink(yellow), builtinType: ink(yellow), module: ink(fg1),
                builtinVariable: ink(orange), property: ink(blue), tag: ink(orange), parameter: ink(blue),
                operator: ink(orange), punctuation: ink(orange), bracket: ink(orange), heading: ink(green).bold)))
    }

    // MARK: Nord

    static let nord = EditorTheme(name: "Nord", isDark: true, palette: Palette(
        dark: true, background: hex(0x2E3440), currentLine: hex(0x3B4252), text: hex(0xD8DEE9), lineNumber: hex(0x4C566A),
        cursor: hex(0xD8DEE9), selection: hex(0x434C5E), search: hex(0x88C0D0, 0.35), currentSearch: hex(0x5E81AC, 0.6),
        error: hex(0xBF616A),
        syntax: Syntax(
            comment: ink(0x616E88), keyword: ink(0x81A1C1), string: ink(0xA3BE8C), escape: ink(0xEBCB8B),
            builtinFunction: ink(0x88C0D0), label: ink(0x81A1C1), link: ink(0x88C0D0),
            number: ink(0xB48EAD), constant: ink(0xD8DEE9), boolean: ink(0x81A1C1), builtinConstant: ink(0xD8DEE9),
            attribute: ink(0xD08770), function: ink(0x88C0D0), type: ink(0x81A1C1), builtinType: ink(0xD8DEE9),
            module: ink(0x81A1C1), builtinVariable: ink(0x81A1C1), property: ink(0xD8DEE9), tag: ink(0x81A1C1),
            parameter: ink(0xD8DEE9), operator: ink(0x81A1C1), punctuation: ink(0xECEFF4), bracket: ink(0xECEFF4),
            heading: ink(0x88C0D0))))

    // MARK: One (Atom's legacy rules, the One Dark people know)

    static let oneDark = EditorTheme(name: "One Dark", isDark: true, palette: Palette(
        dark: true, background: hex(0x282C34), currentLine: hex(0x99BBFF, 0.04), text: hex(0xABB2BF), lineNumber: hex(0x636D83),
        cursor: hex(0x528BFF), selection: hex(0x3E4451), search: hex(0x528BFF, 0.24), currentSearch: hex(0x528BFF, 0.5),
        error: hex(0xE05252),
        syntax: Syntax(
            comment: ink(0x5C6370).italic, keyword: ink(0xC678DD), string: ink(0x98C379), escape: ink(0x56B6C2),
            builtinFunction: ink(0x56B6C2), label: ink(0xABB2BF), link: ink(0x56B6C2),
            number: ink(0xD19A66), constant: ink(0xD19A66), boolean: ink(0xD19A66), builtinConstant: ink(0xD19A66),
            attribute: ink(0xC678DD), function: ink(0x61AFEF), type: ink(0xE5C07B), builtinType: ink(0xC678DD),
            module: ink(0xABB2BF), builtinVariable: ink(0xE06C75), property: ink(0xE06C75), tag: ink(0xE06C75),
            parameter: ink(0xABB2BF), operator: ink(0xC678DD), punctuation: ink(0xABB2BF), bracket: ink(0xABB2BF),
            heading: ink(0xE06C75))))

    static let oneLight = EditorTheme(name: "One Light", isDark: false, palette: Palette(
        dark: false, background: hex(0xFAFAFA), currentLine: hex(0x383A42, 0.05), text: hex(0x383A42), lineNumber: hex(0x9D9D9F),
        cursor: hex(0x526FFF), selection: hex(0xE5E5E6), search: hex(0x526FFF, 0.2), currentSearch: hex(0x526FFF, 0.4),
        error: hex(0xFF1414),
        syntax: Syntax(
            comment: ink(0xA0A1A7).italic, keyword: ink(0xA626A4), string: ink(0x50A14F), escape: ink(0x0184BC),
            builtinFunction: ink(0x0184BC), label: ink(0x383A42), link: ink(0x0184BC),
            number: ink(0xB76B01), constant: ink(0xB76B01), boolean: ink(0xB76B01), builtinConstant: ink(0xB76B01),
            attribute: ink(0xA626A4), function: ink(0x4078F2), type: ink(0xCB7701), builtinType: ink(0xA626A4),
            module: ink(0x383A42), builtinVariable: ink(0xE45649), property: ink(0xE45649), tag: ink(0xE45649),
            parameter: ink(0x383A42), operator: ink(0x383A42), punctuation: ink(0x383A42), bracket: ink(0x383A42),
            heading: ink(0xE45649))))

    // MARK: Rosé Pine

    static let rosePine = rosePineTheme("Rosé Pine", dark: true, base: 0x191724, overlay: 0x26233A, muted: 0x6E6A86,
        subtle: 0x908CAA, text: 0xE0DEF4, highlightHigh: 0x524F67, selection: 0x332D41, search: 0x453935,
        love: 0xEB6F92, gold: 0xF6C177, rose: 0xEBBCBA, pine: 0x31748F, foam: 0x9CCFD8, iris: 0xC4A7E7)

    static let rosePineMoon = rosePineTheme("Rosé Pine Moon", dark: true, base: 0x232136, overlay: 0x393552, muted: 0x6E6A86,
        subtle: 0x908CAA, text: 0xE0DEF4, highlightHigh: 0x56526E, selection: 0x3B3551, search: 0x4D4143,
        love: 0xEB6F92, gold: 0xF6C177, rose: 0xEA9A97, pine: 0x3E8FB0, foam: 0x9CCFD8, iris: 0xC4A7E7)

    static let rosePineDawn = rosePineTheme("Rosé Pine Dawn", dark: false, base: 0xFAF4ED, overlay: 0xF2E9E1, muted: 0x9893A5,
        subtle: 0x797593, text: 0x464261, highlightHigh: 0xCECACD, selection: 0xEAE2E3, search: 0xF7E3C8,
        love: 0xB4637A, gold: 0xEA9D34, rose: 0xD7827E, pine: 0x286983, foam: 0x56949F, iris: 0x907AA9)

    /// rose-pine/neovim's groups at its defaults (bold and italic on).
    private static func rosePineTheme(_ name: String, dark: Bool, base: UInt32, overlay: UInt32, muted: UInt32,
                                      subtle: UInt32, text: UInt32, highlightHigh: UInt32, selection: UInt32,
                                      search: UInt32, love: UInt32, gold: UInt32, rose: UInt32, pine: UInt32,
                                      foam: UInt32, iris: UInt32) -> EditorTheme {
        EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(base), currentLine: hex(overlay), text: hex(text), lineNumber: hex(muted),
            cursor: hex(highlightHigh), cursorText: hex(text), selection: hex(selection), search: hex(search),
            currentSearch: hex(gold, dark ? 0.45 : 0.4), error: hex(love),
            syntax: Syntax(
                comment: ink(subtle).italic, keyword: ink(pine), string: ink(gold), escape: ink(pine),
                builtinFunction: ink(rose).bold, label: ink(foam), link: ink(iris),
                number: ink(gold), constant: ink(gold), boolean: ink(rose), builtinConstant: ink(gold).bold,
                attribute: ink(iris), function: ink(rose), type: ink(foam), builtinType: ink(foam).bold, module: ink(text),
                builtinVariable: ink(love).bold.italic, property: ink(foam).italic, tag: ink(foam), parameter: ink(iris).italic,
                operator: ink(subtle), punctuation: ink(subtle), bracket: ink(subtle), heading: ink(foam).bold)))
    }

    // MARK: Solarized

    static let solarizedDark = solarized("Solarized Dark", dark: true, back: 0x002B36, highlight: 0x073642, body: 0x839496,
        secondary: 0x586E75, selection: hex(0x586E75, 0.5))

    static let solarizedLight = solarized("Solarized Light", dark: false, back: 0xFDF6E3, highlight: 0xEEE8D5, body: 0x657B83,
        secondary: 0x93A1A1, selection: hex(0x93A1A1, 0.4))

    /// The original solarized.vim's groups, reached through Vim's default links. Its reversed
    /// selection (secondary tone behind background-colored text) is the secondary tone,
    /// translucent, since Vie keeps the syntax colors on a selection.
    private static func solarized(_ name: String, dark: Bool, back: UInt32, highlight: UInt32, body: UInt32,
                                  secondary: UInt32, selection: CGColor) -> EditorTheme {
        let yellow: UInt32 = 0xB58900, orange: UInt32 = 0xCB4B16, red: UInt32 = 0xDC322F, violet: UInt32 = 0x6C71C4
        let blue: UInt32 = 0x268BD2, cyan: UInt32 = 0x2AA198, green: UInt32 = 0x859900
        return EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(back), gutter: hex(highlight), currentLine: hex(highlight), text: hex(body),
            lineNumber: hex(secondary), cursor: hex(body), selection: selection,
            search: hex(yellow, dark ? 0.35 : 0.3), currentSearch: hex(orange, dark ? 0.5 : 0.4), error: hex(red),
            syntax: Syntax(
                comment: ink(secondary).italic, keyword: ink(green), string: ink(cyan), escape: ink(red),
                builtinFunction: ink(red), label: ink(green), link: ink(violet),
                number: ink(cyan), constant: ink(cyan), boolean: ink(cyan), builtinConstant: ink(red), attribute: ink(orange),
                function: ink(blue), type: ink(yellow), builtinType: ink(red), module: ink(yellow),
                builtinVariable: ink(red), property: ink(blue), tag: ink(red), parameter: ink(body),
                operator: ink(green), punctuation: ink(body), bracket: ink(body), heading: ink(orange).bold)))
    }

    // MARK: Tokyo Night

    static let tokyoNight = tokyo("Tokyo Night", dark: true, bg: 0x1A1B26, currentLine: 0x292E42, fg: 0xC0CAF5,
        lineNumber: 0x3B4261, selection: 0x283457, search: 0x3D59A1, error: 0xDB4B4B, comment: 0x565F89,
        purple: 0x9D7CD8, magenta: 0xBB9AF7, green: 0x9ECE6A, blue: 0x7AA2F7, blue1: 0x2AC3DE, builtinType: 0x27A1B9,
        cyan: 0x7DCFFF, orange: 0xFF9E64, red: 0xF7768E, green1: 0x73DACA, yellow: 0xE0AF68, blue5: 0x89DDFF,
        fgDark: 0xA9B1D6, teal: 0x1ABC9C)

    static let tokyoNightStorm = tokyo("Tokyo Night Storm", dark: true, bg: 0x24283B, currentLine: 0x292E42, fg: 0xC0CAF5,
        lineNumber: 0x3B4261, selection: 0x2E3C64, search: 0x3D59A1, error: 0xDB4B4B, comment: 0x565F89,
        purple: 0x9D7CD8, magenta: 0xBB9AF7, green: 0x9ECE6A, blue: 0x7AA2F7, blue1: 0x2AC3DE, builtinType: 0x29A4BD,
        cyan: 0x7DCFFF, orange: 0xFF9E64, red: 0xF7768E, green1: 0x73DACA, yellow: 0xE0AF68, blue5: 0x89DDFF,
        fgDark: 0xA9B1D6, teal: 0x1ABC9C)

    static let tokyoNightMoon = tokyo("Tokyo Night Moon", dark: true, bg: 0x222436, currentLine: 0x2F334D, fg: 0xC8D3F5,
        lineNumber: 0x3B4261, selection: 0x2D3F76, search: 0x3E68D7, error: 0xC53B53, comment: 0x636DA6,
        purple: 0xFCA7EA, magenta: 0xC099FF, green: 0xC3E88D, blue: 0x82AAFF, blue1: 0x65BCFF, builtinType: 0x589ED7,
        cyan: 0x86E1FC, orange: 0xFF966C, red: 0xFF757F, green1: 0x4FD6BE, yellow: 0xFFC777, blue5: 0x89DDFF,
        fgDark: 0x828BB8, teal: 0x4FD6BE)

    static let tokyoNightDay = tokyo("Tokyo Night Day", dark: false, bg: 0xE1E2E7, currentLine: 0xC4C8DA, fg: 0x3760BF,
        lineNumber: 0xA8AECB, selection: 0xB7C1E3, search: 0x7890DD, error: 0xC64343, comment: 0x848CB5,
        purple: 0x7847BD, magenta: 0x9854F1, green: 0x587539, blue: 0x2E7DE9, blue1: 0x188092, builtinType: 0x4094A3,
        cyan: 0x007197, orange: 0xB15C00, red: 0xF52A65, green1: 0x387068, yellow: 0x8C6C3E, blue5: 0x006A83,
        fgDark: 0x6172B0, teal: 0x118C74)

    /// tokyonight.nvim's groups (from its generated extras) at its defaults (italic comments
    /// and keywords). Numbers, modules and tags take Constant, PreProc and Statement, which
    /// Neovim links them to.
    private static func tokyo(_ name: String, dark: Bool, bg: UInt32, currentLine: UInt32, fg: UInt32, lineNumber: UInt32,
                              selection: UInt32, search: UInt32, error: UInt32, comment: UInt32, purple: UInt32,
                              magenta: UInt32, green: UInt32, blue: UInt32, blue1: UInt32, builtinType: UInt32,
                              cyan: UInt32, orange: UInt32, red: UInt32, green1: UInt32, yellow: UInt32, blue5: UInt32,
                              fgDark: UInt32, teal: UInt32) -> EditorTheme {
        EditorTheme(name: name, isDark: dark, palette: Palette(
            dark: dark, background: hex(bg), currentLine: hex(currentLine), text: hex(fg), lineNumber: hex(lineNumber),
            cursor: hex(fg), selection: hex(selection), search: hex(search), currentSearch: hex(orange, dark ? 0.5 : 0.35),
            error: hex(error),
            syntax: Syntax(
                comment: ink(comment).italic, keyword: ink(purple).italic, string: ink(green), escape: ink(magenta),
                builtinFunction: ink(blue1), label: ink(blue), link: ink(teal),
                number: ink(orange), constant: ink(orange), boolean: ink(orange), builtinConstant: ink(blue1),
                attribute: ink(cyan), function: ink(blue), type: ink(blue1), builtinType: ink(builtinType), module: ink(cyan),
                builtinVariable: ink(red), property: ink(green1), tag: ink(magenta), parameter: ink(yellow),
                operator: ink(blue5), punctuation: ink(blue5), bracket: ink(fgDark), heading: ink(blue).bold)))
    }
}

private func ink(_ v: UInt32) -> Ink { Ink(color: hex(v)) }

extension Syntax {
    /// dracula/vim's assignments (which match the Dracula VS Code theme): pink keywords, cyan
    /// types, green functions, yellow strings, purple numbers, orange parameters, with types,
    /// parameters and comments in italics. Dracula, Alucard and Neon Light use them.
    static func dracula(foreground: UInt32, comment: UInt32, orange: UInt32, yellow: UInt32, green: UInt32,
                        cyan: UInt32, purple: UInt32, pink: UInt32) -> Syntax {
        Syntax(
            comment: ink(comment).italic, keyword: ink(pink), string: ink(yellow), escape: ink(pink),
            builtinFunction: ink(cyan), label: ink(purple).italic, link: ink(yellow),
            number: ink(purple), constant: ink(purple), boolean: ink(purple), builtinConstant: ink(purple),
            attribute: ink(green).italic, function: ink(green), type: ink(cyan).italic, builtinType: ink(pink),
            module: ink(pink), builtinVariable: ink(purple).italic, property: ink(foreground), tag: ink(cyan),
            parameter: ink(orange).italic, operator: ink(pink), punctuation: ink(foreground), bracket: ink(foreground),
            heading: ink(yellow))
    }
}
