# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Cursor do
  describe '.decode_finished' do
    it 'roundtrips an opaque finished cursor' do
      encoded = described_class.encode_finished(1234.5, 99)
      expect(described_class.decode_finished(encoded)).to eq(finished_at: 1234.5, id: 99)
    end

    it 'returns nil only when no cursor was supplied' do
      expect(described_class.decode_finished(nil)).to be_nil
      expect(described_class.decode_finished('')).to be_nil
    end

    it 'rejects malformed, non-finite and non-positive cursor values' do
      invalid = [
        'not-base64',
        Base64.urlsafe_encode64('NaN:1', padding: false),
        Base64.urlsafe_encode64('1.0:0', padding: false),
        Base64.urlsafe_encode64('1.0:1:extra', padding: false)
      ]

      invalid.each do |value|
        expect { described_class.decode_finished(value) }
          .to raise_error(Async::Background::Web::RequestError, 'invalid cursor')
      end
    end
  end

  describe '.decode_pending' do
    it 'roundtrips an opaque pending cursor' do
      encoded = described_class.encode_pending(555.25, 42)
      expect(described_class.decode_pending(encoded)).to eq(run_at: 555.25, id: 42)
    end
  end
end
