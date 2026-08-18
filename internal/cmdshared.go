package qinternal

import "strings"

// NormalizeFlagArgs lets users place flags before or after positional args.
// It preserves "--" so standard flag terminator semantics remain intact.
func NormalizeFlagArgs(args []string, flagsWithValue map[string]struct{}) []string {
	return NormalizeFlagArgsPreserving(args, flagsWithValue, nil)
}

// NormalizeFlagArgsPreserving keeps the named positional options and their
// values next to component operands while normalizing command-wide flags.
func NormalizeFlagArgsPreserving(args []string, flagsWithValue, positionalFlagsWithValue map[string]struct{}) []string {
	if len(args) == 0 {
		return args
	}

	normalized := make([]string, 0, len(args))
	positionals := make([]string, 0, len(args))
	sawTerminator := false
	sawPositionalFlag := false

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			sawTerminator = true
			positionals = append(positionals, args[i+1:]...)
			break
		}
		if _, ok := positionalFlagsWithValue[arg]; ok {
			sawPositionalFlag = true
			positionals = append(positionals, arg)
			if i+1 < len(args) {
				i++
				positionals = append(positionals, args[i])
			}
			continue
		}
		if strings.HasPrefix(arg, "-") && arg != "-" {
			normalized = append(normalized, arg)
			if strings.Contains(arg, "=") {
				continue
			}
			if _, ok := flagsWithValue[arg]; ok && i+1 < len(args) {
				i++
				normalized = append(normalized, args[i])
			}
			continue
		}
		positionals = append(positionals, arg)
	}

	if sawTerminator || sawPositionalFlag {
		normalized = append(normalized, "--")
	}
	normalized = append(normalized, positionals...)
	return normalized
}
