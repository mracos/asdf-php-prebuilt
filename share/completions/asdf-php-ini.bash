# bash completion for asdf-php-ini.
#
# Install: `source .../share/completions/asdf-php-ini.bash` from your
# ~/.bashrc, or drop into your bash_completion.d.

_asdf_php_ini() {
  local cur prev words cword
  _init_completion || return

  local subs="list get set unset keys help"

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$subs" -- "$cur"))
    return
  fi

  case "${words[1]}" in
    get|set|unset)
      if [[ $cword -eq 2 ]]; then
        local keys
        keys="$(asdf-php-ini keys 2>/dev/null)"
        COMPREPLY=($(compgen -W "$keys" -- "$cur"))
      fi
      ;;
    list)
      COMPREPLY=($(compgen -W "--all" -- "$cur"))
      ;;
  esac
}

complete -F _asdf_php_ini asdf-php-ini
