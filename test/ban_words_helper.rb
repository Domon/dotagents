# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../claude/hooks/ban-words"

FLAGGED = "an affordance that is load-bearing"
CLEAN = "The limit is a soft one. A queue at 51 drains normally."
