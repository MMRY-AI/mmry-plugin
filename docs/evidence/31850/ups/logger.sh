#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
p="$(cat)"; printf '%s %s payload=%s\n' "$(date +%T)" "$1" "$p" >> "$d/log.txt"; exit 0
