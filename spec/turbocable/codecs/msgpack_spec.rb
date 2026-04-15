# frozen_string_literal: true

require "msgpack"

RSpec.describe Turbocable::Codecs::MsgPack do
  before { described_class.reset_factory! }

  # -------------------------------------------------------------------------
  # Codec identity
  # -------------------------------------------------------------------------
  describe ".content_type" do
    it "returns the turbocable-v1-msgpack sub-protocol name" do
      expect(described_class.content_type).to eq("turbocable-v1-msgpack")
    end
  end

  describe "ext type constants" do
    it "defines EXT_TYPE_SYMBOL as 0 (coordinated with JS client)" do
      expect(described_class::EXT_TYPE_SYMBOL).to eq(0)
    end

    it "defines EXT_TYPE_TIME as 1 (coordinated with JS client)" do
      expect(described_class::EXT_TYPE_TIME).to eq(1)
    end
  end

  # -------------------------------------------------------------------------
  # Round-trips
  # -------------------------------------------------------------------------
  describe ".encode / .decode round-trips" do
    it "round-trips a Hash with string keys" do
      payload = {"text" => "hello", "count" => 3}
      expect(described_class.decode(described_class.encode(payload))).to eq(payload)
    end

    it "round-trips a Hash with symbol keys (serialized as ext type 0)" do
      payload = {text: "hello", count: 3}
      result = described_class.decode(described_class.encode(payload))
      expect(result).to eq(payload)
    end

    it "round-trips an Array" do
      payload = [1, "two", 3.0, nil, true, false]
      expect(described_class.decode(described_class.encode(payload))).to eq(payload)
    end

    it "round-trips nil" do
      expect(described_class.decode(described_class.encode(nil))).to be_nil
    end

    it "round-trips integers and floats" do
      payload = {"int" => 42, "float" => 3.14}
      expect(described_class.decode(described_class.encode(payload))).to eq(payload)
    end

    it "round-trips a Time value (serialized as ext type 1, preserved to nanosecond)" do
      t = Time.at(1_700_000_000, 123_456_789, :nsec).utc
      encoded = described_class.encode({ts: t})
      result = described_class.decode(encoded)

      expect(result[:ts].to_i).to eq(t.to_i)
      expect(result[:ts].nsec).to eq(t.nsec)
    end

    it "round-trips a nested Hash" do
      payload = {user: {id: 1, name: "Alice"}, meta: {ts: "2024-01-01"}}
      expect(described_class.decode(described_class.encode(payload))).to eq(payload)
    end
  end

  # -------------------------------------------------------------------------
  # Golden bytes
  #
  # These bytes form the contract between this gem and the TurboCable JS
  # client. String-keyed payloads involve no ext types, making them a stable
  # cross-language anchor. If these bytes change, the JS client must be
  # updated in lockstep.
  # -------------------------------------------------------------------------
  describe "golden bytes" do
    it "encodes a simple string-keyed Hash to the expected bytes" do
      encoded = described_class.encode({"hello" => "world"})
      # fixmap(1)=0x81, fixstr5("hello")=0xa5+bytes, fixstr5("world")=0xa5+bytes
      expected = "\x81\xa5hello\xa5world".b
      expect(encoded).to eq(expected)
    end

    it "encodes an empty Hash to a single fixmap(0) byte" do
      expect(described_class.encode({})).to eq("\x80".b)
    end

    it "encodes nil to the nil byte" do
      expect(described_class.encode(nil)).to eq("\xc0".b)
    end
  end

  # -------------------------------------------------------------------------
  # Server decodability
  # The server uses rmp_serde::from_slice which parses standard MessagePack.
  # Ext types are valid MessagePack — the server sees them as opaque Ext
  # values before forwarding bytes to WebSocket subscribers.
  # -------------------------------------------------------------------------
  describe "server decodability" do
    it "produces bytes decodable by plain msgpack (as the server sees the payload)" do
      payload = {"message" => "hello", "user_id" => 42}
      encoded = described_class.encode(payload)
      expect { ::MessagePack.unpack(encoded) }.not_to raise_error
    end

    it "produces bytes decodable when symbols are present (ext type is valid msgpack)" do
      payload = {channel: "chat_room_42", text: "hi"}
      encoded = described_class.encode(payload)
      expect { ::MessagePack.unpack(encoded) }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # Error handling
  # -------------------------------------------------------------------------
  describe ".encode error handling" do
    it "raises SerializationError for types that cannot be packed" do
      expect { described_class.encode(Object.new) }
        .to raise_error(Turbocable::SerializationError) do |e|
          expect(e.codec_name).to eq(:msgpack)
          expect(e.payload_class).to eq(Object)
        end
    end

    it "includes the payload class in the error message" do
      expect { described_class.encode(StringIO.new) }
        .to raise_error(Turbocable::SerializationError, /StringIO/)
    end
  end

  # -------------------------------------------------------------------------
  # LoadError when msgpack gem is absent
  # -------------------------------------------------------------------------
  describe "LoadError when msgpack is unavailable" do
    it "raises LoadError with install instructions" do
      described_class.reset_factory!
      allow(described_class).to receive(:require_msgpack!)
        .and_raise(::LoadError, "cannot load such file -- msgpack")

      expect { described_class.encode({}) }
        .to raise_error(::LoadError, /cannot load such file -- msgpack/)
    end
  end

  # -------------------------------------------------------------------------
  # Registry integration
  # -------------------------------------------------------------------------
  describe "Codecs.fetch(:msgpack)" do
    it "returns Turbocable::Codecs::MsgPack" do
      expect(Turbocable::Codecs.fetch(:msgpack)).to be(described_class)
    end
  end
end
