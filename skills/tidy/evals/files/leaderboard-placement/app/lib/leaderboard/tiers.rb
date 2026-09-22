# frozen_string_literal: true

module Leaderboard
  module Tiers
    CEILINGS = [ [ "gold", 0.1 ], [ "silver", 0.3 ], [ "bronze", 1.0 ] ].freeze

    module_function

    def name_for(fraction)
      CEILINGS.find { |_name, ceiling| fraction <= ceiling }&.first
    end

    def label(name)
      name.to_s.capitalize
    end
  end
end
