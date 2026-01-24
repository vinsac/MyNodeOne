#!/bin/bash
# MyNodeOne Validation Framework
# Provides functions for validating shell scripts and configurations

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate shell syntax
validate_shell_syntax() {
    local script="$1"
    local verbose="${2:-false}"
    
    if [ ! -f "$script" ]; then
        echo -e "${RED}Error: File '$script' not found${NC}" >&2
        return 1
    fi
    
    if bash -n "$script" 2>/dev/null; then
        [ "$verbose" = "true" ] && echo -e "${GREEN}✓ Syntax valid: $script${NC}"
        return 0
    else
        [ "$verbose" = "true" ] && echo -e "${RED}✗ Syntax error in: $script${NC}"
        bash -n "$script" 2>&1 | sed 's/^/  /' >&2
        return 1
    fi
}

# Validate shell quoting in command substitutions
validate_quoting() {
    local script="$1"
    local verbose="${2:-false}"
    local errors=0
    
    # Check for unescaped quotes in command substitutions
    while IFS= read -r line; do
        # Pattern: $(command "unclosed)
        if [[ "$line" =~ \$\([^\)]*\"[^\"]*$ ]]; then
            [ "$verbose" = "true" ] && echo -e "${RED}✗ Unescaped quote in command substitution:${NC}" >&2
            [ "$verbose" = "true" ] && echo "  $line" >&2
            errors=$((errors + 1))
        fi
        
        # Pattern: $(command 'unclosed)
        if [[ "$line" =~ \$\([^\)]*\'[^\']*$ ]]; then
            [ "$verbose" = "true" ] && echo -e "${RED}✗ Unescaped single quote in command substitution:${NC}" >&2
            [ "$verbose" = "true" ] && echo "  $line" >&2
            errors=$((errors + 1))
        fi
    done < "$script"
    
    return $errors
}

# Validate common anti-patterns
validate_antipatterns() {
    local script="$1"
    local verbose="${2:-false}"
    local errors=0
    
    while IFS= read -r line; do
        # Check for cd without error handling
        if [[ "$line" =~ ^[[:space:]]*cd[[:space:]]+[^[:space:]]+[[:space:]]*$ ]] && [[ ! "$line" =~ \|\| ]] && [[ ! "$line" =~ \&\& ]]; then
            [ "$verbose" = "true" ] && echo -e "${YELLOW}⚠ cd without error handling:${NC}" >&2
            [ "$verbose" = "true" ] && echo "  $line" >&2
        fi
        
        # Check for rm -rf without variable check
        if [[ "$line" =~ rm[[:space:]]+-rf[[:space:]]+\$ ]]; then
            [ "$verbose" = "true" ] && echo -e "${YELLOW}⚠ rm -rf with variable (should check if empty):${NC}" >&2
            [ "$verbose" = "true" ] && echo "  $line" >&2
        fi
    done < "$script"
    
    return $errors
}

# Validate script has proper error handling
validate_error_handling() {
    local script="$1"
    local verbose="${2:-false}"
    local warnings=0
    
    # Check if script has set -euo pipefail or similar
    if ! grep -q "set -e" "$script"; then
        [ "$verbose" = "true" ] && echo -e "${YELLOW}⚠ Missing 'set -e' for error handling${NC}" >&2
        warnings=$((warnings + 1))
    fi
    
    # Check if script uses proper exit codes
    if ! grep -q "exit [0-9]" "$script" && ! grep -q "return [0-9]" "$script"; then
        [ "$verbose" = "true" ] && echo -e "${YELLOW}⚠ No explicit exit/return codes found${NC}" >&2
        warnings=$((warnings + 1))
    fi
    
    return $warnings
}

# Comprehensive validation
validate_script_comprehensive() {
    local script="$1"
    local verbose="${2:-false}"
    local total_errors=0
    local total_warnings=0
    
    [ "$verbose" = "true" ] && echo -e "${BLUE}Validating: $script${NC}"
    
    # Syntax check
    if ! validate_shell_syntax "$script" "$verbose"; then
        total_errors=$((total_errors + 1))
    fi
    
    # Quoting check
    local quoting_errors
    quoting_errors=$(validate_quoting "$script" "$verbose"; echo $?)
    total_errors=$((total_errors + quoting_errors))
    
    # Anti-patterns check
    local antipattern_errors
    antipattern_errors=$(validate_antipatterns "$script" "$verbose"; echo $?)
    total_warnings=$((total_warnings + antipattern_errors))
    
    # Error handling check
    local handling_warnings
    handling_warnings=$(validate_error_handling "$script" "$verbose"; echo $?)
    total_warnings=$((total_warnings + handling_warnings))
    
    if [ "$verbose" = "true" ]; then
        if [ $total_errors -eq 0 ]; then
            echo -e "${GREEN}✓ Passed validation${NC}"
        else
            echo -e "${RED}✗ Failed validation ($total_errors errors, $total_warnings warnings)${NC}"
        fi
    fi
    
    return $total_errors
}

# Validate all scripts in a directory
validate_directory() {
    local directory="$1"
    local recursive="${2:-false}"
    local verbose="${3:-false}"
    local total_errors=0
    
    if [ "$recursive" = "true" ]; then
        find "$directory" -type f -name "*.sh" | while read -r script; do
            if ! validate_script_comprehensive "$script" "$verbose"; then
                total_errors=$((total_errors + 1))
            fi
        done
    else
        find "$directory" -maxdepth 1 -type f -name "*.sh" | while read -r script; do
            if ! validate_script_comprehensive "$script" "$verbose"; then
                total_errors=$((total_errors + 1))
            fi
        done
    fi
    
    return $total_errors
}

# Export functions for use in other scripts
export -f validate_shell_syntax
export -f validate_quoting
export -f validate_antipatterns
export -f validate_error_handling
export -f validate_script_comprehensive
export -f validate_directory
