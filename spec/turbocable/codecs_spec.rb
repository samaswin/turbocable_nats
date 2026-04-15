# frozen_string_literal: true

RSpec.describe Turbocable::Codecs do
  describe ".fetch" do
    it "returns the JSON codec for :json" do
      expect(described_class.fetch(:json)).to be(Turbocable::Codecs::JSON)
    end

    it "accepts string keys by converting to symbol" do
      expect(described_class.fetch("json")).to be(Turbocable::Codecs::JSON)
    end

    it "raises ConfigurationError for unknown codecs" do
      expect { described_class.fetch(:nonexistent) }
        .to raise_error(Turbocable::ConfigurationError, /nonexistent/)
    end

    it "includes available codec names in the error message" do
      expect { described_class.fetch(:bogus) }
        .to raise_error(Turbocable::ConfigurationError, /:json/)
    end
  end

  describe ".registered" do
    it "includes :json" do
      expect(described_class.registered).to include(:json)
    end

    it "includes :msgpack" do
      expect(described_class.registered).to include(:msgpack)
    end
  end
end

RSpec.describe Turbocable::Codecs::JSON do
  describe ".content_type" do
    it "returns the actioncable-v1-json sub-protocol name" do
      expect(described_class.content_type).to eq("actioncable-v1-json")
    end
  end

  describe ".encode" do
    it "serializes a Hash to a JSON string" do
      result = described_class.encode({text: "hello", count: 3})
      expect(result).to be_a(String)
      parsed = ::JSON.parse(result)
      expect(parsed["text"]).to eq("hello")
      expect(parsed["count"]).to eq(3)
    end

    it "serializes an Array" do
      result = described_class.encode([1, 2, 3])
      expect(::JSON.parse(result)).to eq([1, 2, 3])
    end

    it "serializes strings" do
      expect(described_class.encode("hello")).to eq('"hello"')
    end

    it "serializes nil" do
      expect(described_class.encode(nil)).to eq("null")
    end

    it "raises SerializationError for un-encodable values" do
      # An IO object cannot be JSON-serialized
      expect { described_class.encode(StringIO.new("x")) }
        .to raise_error(Turbocable::SerializationError) do |e|
          expect(e.codec_name).to eq(:json)
          expect(e.payload_class).to eq(StringIO)
        end
    end
  end

  describe ".decode" do
    it "round-trips a Hash" do
      original = {"text" => "hello", "count" => 3}
      encoded  = described_class.encode(original)
      decoded  = described_class.decode(encoded)
      expect(decoded).to eq(original)
    end

    it "round-trips an Array" do
      original = [1, "two", {three: 3}]
      encoded  = described_class.encode(original)
      decoded  = described_class.decode(encoded)
      # Symbol keys become strings through JSON
      expect(decoded).to eq([1, "two", {"three" => 3}])
    end
  end
end
