# frozen_string_literal: true

module Async
  module Background
    module Queue
      EMPTY_ARGS = [].freeze
      EMPTY_OPTIONS = {}.freeze

      SYNCHRONOUS_LEVELS = {normal: 'NORMAL', full: 'FULL', extra: 'EXTRA'}.freeze
      WAL_AUTOCHECKPOINT_RANGE = 100..10_000
      DEFAULT_STORE_OPTIONS = {mmap: true, synchronous: :normal, wal_autocheckpoint: 1_000}.freeze
      DEFAULTS = DEFAULT_STORE_OPTIONS
      MMAP_SIZE = 268_435_456

      StoreOptions = Data.define(:mmap, :synchronous, :wal_autocheckpoint) do
        def self.build(value = {})
          return value if value.is_a?(self)

          new(**DEFAULT_STORE_OPTIONS, **value)
        end

        def initialize(mmap:, synchronous:, wal_autocheckpoint:)
          validate_mmap!(mmap)
          validate_synchronous!(synchronous)
          validate_wal_autocheckpoint!(wal_autocheckpoint)

          super
        end

        def synchronous_pragma = SYNCHRONOUS_LEVELS.fetch(synchronous)
        def mmap_size = mmap ? MMAP_SIZE : 0

        def pragma_sql
          <<~SQL
            PRAGMA journal_mode       = WAL;
            PRAGMA synchronous        = #{synchronous_pragma};
            PRAGMA mmap_size          = #{mmap_size};
            PRAGMA cache_size         = -16000;
            PRAGMA temp_store         = MEMORY;
            PRAGMA journal_size_limit = 67108864;
            PRAGMA wal_autocheckpoint = #{wal_autocheckpoint};
          SQL
        end

        private

        def validate_mmap!(value)
          return if value == true || value == false

          raise ArgumentError, "mmap must be true or false, got #{value.inspect}"
        end

        def validate_synchronous!(value)
          return if SYNCHRONOUS_LEVELS.key?(value)

          raise ArgumentError,
                "synchronous must be one of #{SYNCHRONOUS_LEVELS.keys.inspect}, got #{value.inspect}"
        end

        def validate_wal_autocheckpoint!(value)
          return if value.is_a?(Integer) && WAL_AUTOCHECKPOINT_RANGE.cover?(value)

          raise ArgumentError,
                "wal_autocheckpoint must be an Integer in #{WAL_AUTOCHECKPOINT_RANGE}, " \
                "got #{value.inspect}"
        end
      end
    end
  end
end
