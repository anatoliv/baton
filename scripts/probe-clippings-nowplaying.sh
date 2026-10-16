#!/bin/bash
# The Clippings now-playing walk (TBX-10990), on a probe instance, never the owner's Baton:
#
#   scripts/probe-clippings-nowplaying.sh <Baton.app> <evidence-dir>
#
# Seeds the probe's own Clippings with two readings and a two-chapter book, each a real
# 40-second audio file, then:
#
#   A. nothing playing: no row is marked
#   B. chapter 2 played from its row's menu: the chapter row has the bars, the accent title and
#      the tint, and the book row has the bars alone
#   C. paused: the tint stays on the chapter row, the bars go (the Mac's music rows do the same)
#   D. a reading played from its row's menu: that row has the bars and the tint, the book none
#
# Playback state is read from the probe's own MCP `baton://now-playing` resource, so a verdict
# never depends on reading a screenshot. Rows are opened through the Accessibility API
# (scripts/probe-ax.swift); nothing is typed or clicked into whatever is in front.
#
# Exit 0 PASS, 1 FAIL, 2 could not run, 3 another probe holds the lock (probe-lib.sh).
#
# Since TBX-11018 a book's chapters are in Books, not in Clippings, so the chapter steps (B, C)
# moved to scripts/probe-books-section.sh, which walks Clippings, Books, an open book and the bars
# on a playing chapter. This name is kept so the TBX-10990 evidence and older notes still lead
# somewhere; it runs that walk.
exec "$(dirname "$0")/probe-books-section.sh" "$@"
