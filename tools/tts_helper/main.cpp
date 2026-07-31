#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr const char *kVersion = "0.1.0";
constexpr int kProtocolVersion = 1;
constexpr int kMaxJsonDepth = 64;

struct JsonValue {
	enum class Type { Null, Boolean, Number, String, Array, Object };

	Type type = Type::Null;
	bool boolean = false;
	std::string text;
	std::vector<JsonValue> array;
	std::map<std::string, JsonValue> object;
};

void append_utf8(std::string &out, std::uint32_t codepoint) {
	if (codepoint <= 0x7f) {
		out.push_back(static_cast<char>(codepoint));
	} else if (codepoint <= 0x7ff) {
		out.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
		out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
	} else if (codepoint <= 0xffff) {
		out.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
		out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
		out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
	} else {
		out.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
		out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
		out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
		out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
	}
}

class JsonParser {
public:
	explicit JsonParser(const std::string &source) : source_(source) {}

	bool parse(JsonValue &value, std::string &error) {
		skip_space();
		if (!parse_value(value, 0)) {
			error = error_;
			return false;
		}
		skip_space();
		if (position_ != source_.size()) {
			fail("unexpected characters after JSON value");
			error = error_;
			return false;
		}
		return true;
	}

private:
	bool parse_value(JsonValue &value, int depth) {
		if (depth > kMaxJsonDepth) {
			return fail("JSON nesting is too deep");
		}
		if (position_ >= source_.size()) {
			return fail("expected a JSON value");
		}
		switch (source_[position_]) {
			case 'n':
				return parse_literal("null", JsonValue::Type::Null, value);
			case 't':
				value.boolean = true;
				return parse_literal("true", JsonValue::Type::Boolean, value);
			case 'f':
				value.boolean = false;
				return parse_literal("false", JsonValue::Type::Boolean, value);
			case '"':
				value.type = JsonValue::Type::String;
				return parse_string(value.text);
			case '[':
				return parse_array(value, depth + 1);
			case '{':
				return parse_object(value, depth + 1);
			default:
				if (source_[position_] == '-' ||
						(source_[position_] >= '0' && source_[position_] <= '9')) {
					return parse_number(value);
				}
				return fail("invalid JSON value");
		}
	}

	bool parse_literal(const char *literal, JsonValue::Type type, JsonValue &value) {
		const std::string wanted(literal);
		if (source_.compare(position_, wanted.size(), wanted) != 0) {
			return fail("invalid JSON literal");
		}
		position_ += wanted.size();
		value.type = type;
		return true;
	}

	bool parse_string(std::string &result) {
		if (!take('"')) {
			return fail("expected a JSON string");
		}
		result.clear();
		while (position_ < source_.size()) {
			const unsigned char byte = static_cast<unsigned char>(source_[position_++]);
			if (byte == '"') {
				return true;
			}
			if (byte < 0x20) {
				return fail("unescaped control character in JSON string");
			}
			if (byte != '\\') {
				if (byte < 0x80) {
					result.push_back(static_cast<char>(byte));
				} else if (!append_raw_utf8(result, byte)) {
					return false;
				}
				continue;
			}
			if (position_ >= source_.size()) {
				return fail("unfinished JSON escape");
			}
			const char escape = source_[position_++];
			switch (escape) {
				case '"':
				result.push_back('"');
				break;
				case '\\':
				result.push_back('\\');
				break;
				case '/':
					result.push_back('/');
					break;
				case 'b':
					result.push_back('\b');
					break;
				case 'f':
					result.push_back('\f');
					break;
				case 'n':
					result.push_back('\n');
					break;
				case 'r':
					result.push_back('\r');
					break;
				case 't':
					result.push_back('\t');
					break;
				case 'u': {
					std::uint32_t codepoint = 0;
					if (!parse_hex_quad(codepoint)) {
						return false;
					}
					if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
						if (position_ + 2 > source_.size() ||
								source_[position_] != '\\' || source_[position_ + 1] != 'u') {
							return fail("high surrogate is missing its low surrogate");
						}
						position_ += 2;
						std::uint32_t low = 0;
						if (!parse_hex_quad(low)) {
							return false;
						}
						if (low < 0xdc00 || low > 0xdfff) {
							return fail("invalid low surrogate");
						}
						codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
					} else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
						return fail("unexpected low surrogate");
					}
					append_utf8(result, codepoint);
					break;
				}
				default:
					return fail("invalid JSON escape");
			}
		}
		return fail("unterminated JSON string");
	}

	bool append_raw_utf8(std::string &result, unsigned char lead) {
		int continuation_count = 0;
		unsigned char second_min = 0x80;
		unsigned char second_max = 0xbf;
		if (lead >= 0xc2 && lead <= 0xdf) {
			continuation_count = 1;
		} else if (lead >= 0xe0 && lead <= 0xef) {
			continuation_count = 2;
			if (lead == 0xe0) {
				second_min = 0xa0;  // Reject overlong encodings.
			} else if (lead == 0xed) {
				second_max = 0x9f;  // Reject UTF-16 surrogate code points.
			}
		} else if (lead >= 0xf0 && lead <= 0xf4) {
			continuation_count = 3;
			if (lead == 0xf0) {
				second_min = 0x90;  // Reject overlong encodings.
			} else if (lead == 0xf4) {
				second_max = 0x8f;  // Reject values above U+10FFFF.
			}
		} else {
			return fail("invalid UTF-8 lead byte in JSON string");
		}

		if (position_ + static_cast<std::size_t>(continuation_count) > source_.size()) {
			return fail("truncated UTF-8 sequence in JSON string");
		}
		const unsigned char second = static_cast<unsigned char>(source_[position_]);
		if (second < second_min || second > second_max) {
			return fail("invalid UTF-8 continuation byte in JSON string");
		}
		for (int index = 1; index < continuation_count; ++index) {
			const unsigned char continuation =
					static_cast<unsigned char>(source_[position_ + index]);
			if (continuation < 0x80 || continuation > 0xbf) {
				return fail("invalid UTF-8 continuation byte in JSON string");
			}
		}

		result.push_back(static_cast<char>(lead));
		result.append(source_, position_, static_cast<std::size_t>(continuation_count));
		position_ += static_cast<std::size_t>(continuation_count);
		return true;
	}

	bool parse_hex_quad(std::uint32_t &value) {
		if (position_ + 4 > source_.size()) {
			return fail("short Unicode escape");
		}
		value = 0;
		for (int index = 0; index < 4; ++index) {
			const char digit = source_[position_++];
			value <<= 4;
			if (digit >= '0' && digit <= '9') {
				value |= static_cast<std::uint32_t>(digit - '0');
			} else if (digit >= 'a' && digit <= 'f') {
				value |= static_cast<std::uint32_t>(digit - 'a' + 10);
			} else if (digit >= 'A' && digit <= 'F') {
				value |= static_cast<std::uint32_t>(digit - 'A' + 10);
			} else {
				return fail("invalid hexadecimal digit in Unicode escape");
			}
		}
		return true;
	}

	bool parse_number(JsonValue &value) {
		const std::size_t begin = position_;
		if (peek('-')) {
			++position_;
		}
		if (position_ >= source_.size()) {
			return fail("unfinished JSON number");
		}
		if (peek('0')) {
			++position_;
			if (position_ < source_.size() && source_[position_] >= '0' &&
					source_[position_] <= '9') {
				return fail("leading zero in JSON number");
			}
		} else {
			if (source_[position_] < '1' || source_[position_] > '9') {
				return fail("invalid JSON number");
			}
			while (position_ < source_.size() && source_[position_] >= '0' &&
					source_[position_] <= '9') {
				++position_;
			}
		}
		if (peek('.')) {
			++position_;
			if (position_ >= source_.size() || source_[position_] < '0' ||
					source_[position_] > '9') {
				return fail("fraction has no digits");
			}
			while (position_ < source_.size() && source_[position_] >= '0' &&
					source_[position_] <= '9') {
				++position_;
			}
		}
		if (peek('e') || peek('E')) {
			++position_;
			if (peek('+') || peek('-')) {
				++position_;
			}
			if (position_ >= source_.size() || source_[position_] < '0' ||
					source_[position_] > '9') {
				return fail("exponent has no digits");
			}
			while (position_ < source_.size() && source_[position_] >= '0' &&
					source_[position_] <= '9') {
				++position_;
			}
		}
		value.type = JsonValue::Type::Number;
		value.text = source_.substr(begin, position_ - begin);
		return true;
	}

	bool parse_array(JsonValue &value, int depth) {
		take('[');
		value.type = JsonValue::Type::Array;
		value.array.clear();
		skip_space();
		if (take(']')) {
			return true;
		}
		while (true) {
			JsonValue item;
			if (!parse_value(item, depth)) {
				return false;
			}
			value.array.push_back(std::move(item));
			skip_space();
			if (take(']')) {
				return true;
			}
			if (!take(',')) {
				return fail("expected comma or closing bracket");
			}
			skip_space();
		}
	}

	bool parse_object(JsonValue &value, int depth) {
		take('{');
		value.type = JsonValue::Type::Object;
		value.object.clear();
		skip_space();
		if (take('}')) {
			return true;
		}
		while (true) {
			if (!peek('"')) {
				return fail("object key is not a string");
			}
			std::string key;
			if (!parse_string(key)) {
				return false;
			}
			skip_space();
			if (!take(':')) {
				return fail("expected colon after object key");
			}
			skip_space();
			JsonValue item;
			if (!parse_value(item, depth)) {
				return false;
			}
			if (!value.object.emplace(std::move(key), std::move(item)).second) {
				return fail("duplicate object key");
			}
			skip_space();
			if (take('}')) {
				return true;
			}
			if (!take(',')) {
				return fail("expected comma or closing brace");
			}
			skip_space();
		}
	}

	void skip_space() {
		while (position_ < source_.size()) {
			const char current = source_[position_];
			if (current != ' ' && current != '\t' && current != '\r' && current != '\n') {
				break;
			}
			++position_;
		}
	}

	bool peek(char wanted) const {
		return position_ < source_.size() && source_[position_] == wanted;
	}

	bool take(char wanted) {
		if (!peek(wanted)) {
			return false;
		}
		++position_;
		return true;
	}

	bool fail(const std::string &message) {
		if (error_.empty()) {
			std::ostringstream formatted;
			formatted << message << " at byte " << position_;
			error_ = formatted.str();
		}
		return false;
	}

	const std::string &source_;
	std::size_t position_ = 0;
	std::string error_;
};

std::string escape_json(const std::string &input) {
	static constexpr char kHex[] = "0123456789abcdef";
	std::string output;
	output.reserve(input.size() + 8);
	for (const unsigned char byte : input) {
		switch (byte) {
			case '"':
				output += "\\\"";
				break;
			case '\\':
				output += "\\\\";
				break;
			case '\b':
				output += "\\b";
				break;
			case '\f':
				output += "\\f";
				break;
			case '\n':
				output += "\\n";
				break;
			case '\r':
				output += "\\r";
				break;
			case '\t':
				output += "\\t";
				break;
			default:
				if (byte < 0x20) {
					output += "\\u00";
					output.push_back(kHex[(byte >> 4) & 0x0f]);
					output.push_back(kHex[byte & 0x0f]);
				} else {
					output.push_back(static_cast<char>(byte));
				}
		}
	}
	return output;
}

const JsonValue *member(const JsonValue &object, const std::string &key) {
	const auto found = object.object.find(key);
	return found == object.object.end() ? nullptr : &found->second;
}

bool integer_value(const JsonValue &value, std::int64_t &result) {
	if (value.type != JsonValue::Type::Number || value.text.empty() ||
			value.text.find_first_of(".eE") != std::string::npos) {
		return false;
	}
	try {
		std::size_t used = 0;
		const long long converted = std::stoll(value.text, &used, 10);
		if (used != value.text.size()) {
			return false;
		}
		result = static_cast<std::int64_t>(converted);
		return true;
	} catch (const std::exception &) {
		return false;
	}
}

struct Options {
	std::string models;
	std::string output;
	std::string spool;
	std::string log;
	int threads = 0;
	double idle = 0.0;
	int protocol = 0;
};

bool parse_int(const std::string &text, int &value) {
	try {
		std::size_t used = 0;
		const long converted = std::stol(text, &used, 10);
		if (used != text.size() || converted < std::numeric_limits<int>::min() ||
				converted > std::numeric_limits<int>::max()) {
			return false;
		}
		value = static_cast<int>(converted);
		return true;
	} catch (const std::exception &) {
		return false;
	}
}

bool parse_double(const std::string &text, double &value) {
	try {
		std::size_t used = 0;
		value = std::stod(text, &used);
		return used == text.size() && std::isfinite(value);
	} catch (const std::exception &) {
		return false;
	}
}

bool parse_options(int argc, char **argv, Options &options, std::string &error) {
	std::map<std::string, std::string *> strings = {
		{"--models", &options.models},
		{"--out", &options.output},
		{"--spool", &options.spool},
		{"--log", &options.log},
	};
	std::string threads;
	std::string idle;
	std::string protocol;
	strings["--threads"] = &threads;
	strings["--idle"] = &idle;
	strings["--protocol"] = &protocol;

	for (int index = 1; index < argc; index += 2) {
		const std::string flag(argv[index]);
		const auto destination = strings.find(flag);
		if (destination == strings.end()) {
			error = "unknown argument: " + flag;
			return false;
		}
		if (index + 1 >= argc) {
			error = "missing value for " + flag;
			return false;
		}
		if (!destination->second->empty()) {
			error = "duplicate argument: " + flag;
			return false;
		}
		*destination->second = argv[index + 1];
	}

	for (const auto &entry : strings) {
		if (entry.second->empty()) {
			error = "missing required argument: " + entry.first;
			return false;
		}
	}
	if (!parse_int(threads, options.threads) || options.threads <= 0) {
		error = "--threads must be a positive integer";
		return false;
	}
	if (!parse_double(idle, options.idle) || options.idle < 0.0) {
		error = "--idle must be a non-negative number";
		return false;
	}
	if (!parse_int(protocol, options.protocol) || options.protocol != kProtocolVersion) {
		error = "unsupported protocol version";
		return false;
	}
	return true;
}

class Responder {
public:
	explicit Responder(const std::string &path) : stream_(path, std::ios::app) {
		if (!stream_) {
			throw std::runtime_error("cannot open response file: " + path);
		}
	}

	void ready() {
		send("{\"event\":\"ready\",\"protocol\":1,\"engine\":\"unavailable\"}");
	}

	void unavailable(std::int64_t id, const std::string &op) {
		std::ostringstream event;
		event << "{\"event\":\"error\",\"id\":" << id
			  << ",\"op\":\"" << escape_json(op)
			  << "\",\"code\":\"engine_unavailable\","
			  << "\"message\":\"qwen engine is not linked\"}";
		send(event.str());
	}

	void malformed(std::int64_t id, const std::string &op, const std::string &message) {
		std::ostringstream event;
		event << "{\"event\":\"error\",\"id\":" << id
			  << ",\"op\":\"" << escape_json(op)
			  << "\",\"code\":\"malformed_request\","
			  << "\"message\":\"" << escape_json(message) << "\"}";
		send(event.str());
	}

	void bye() {
		send("{\"event\":\"bye\"}");
	}

private:
	void send(const std::string &line) {
		stream_ << line << '\n';
		stream_.flush();
		if (!stream_) {
			throw std::runtime_error("cannot write response file");
		}
	}

	std::ofstream stream_;
};

bool internal_self_test() {
	const std::string sample =
			R"({"op":"say","id":77,"text":"他說：「你好，\\\"朋友\\\"」","emoji":"\ud83d\udc3e"})";
	JsonValue value;
	std::string error;
	if (!JsonParser(sample).parse(value, error) || value.type != JsonValue::Type::Object) {
		return false;
	}
	const JsonValue *op = member(value, "op");
	const JsonValue *id = member(value, "id");
	std::int64_t request_id = 0;
	return op != nullptr && op->type == JsonValue::Type::String && op->text == "say" &&
			id != nullptr && integer_value(*id, request_id) && request_id == 77;
}

int run(const Options &options) {
	std::error_code filesystem_error;
	std::filesystem::create_directories(options.spool, filesystem_error);
	if (filesystem_error) {
		std::cerr << "cannot create spool directory: " << filesystem_error.message() << '\n';
		return 2;
	}

	const std::filesystem::path log_path(options.log);
	if (log_path.has_parent_path()) {
		std::filesystem::create_directories(log_path.parent_path(), filesystem_error);
		if (filesystem_error) {
			std::cerr << "cannot create log directory: " << filesystem_error.message() << '\n';
			return 2;
		}
	}
	std::ofstream log(options.log, std::ios::app);
	if (!log) {
		std::cerr << "cannot open log file\n";
		return 2;
	}
	log << "native TTS protocol stub " << kVersion << " started; models="
		<< options.models << " threads=" << options.threads << " idle=" << options.idle << '\n';
	log.flush();

	try {
		Responder responder(options.output);
		responder.ready();
		std::string line;
		bool quit_requested = false;
		while (std::getline(std::cin, line)) {
			if (line.find_first_not_of(" \t\r\n") == std::string::npos) {
				continue;
			}

			JsonValue request;
			std::string parse_error;
			if (!JsonParser(line).parse(request, parse_error) ||
					request.type != JsonValue::Type::Object) {
				responder.malformed(0, "request",
						parse_error.empty() ? "request must be a JSON object" : parse_error);
				continue;
			}

			std::int64_t id = 0;
			const JsonValue *id_value = member(request, "id");
			const bool has_valid_id =
					id_value != nullptr && integer_value(*id_value, id) && id >= 0;
			if (!has_valid_id) {
				id = 0;
			}

			const JsonValue *op_value = member(request, "op");
			const bool has_valid_op = op_value != nullptr &&
					op_value->type == JsonValue::Type::String && !op_value->text.empty();
			const std::string op = has_valid_op ? op_value->text : "request";
			if (!has_valid_op) {
				responder.malformed(id, op, "request has no non-empty string op");
				continue;
			}
			if (op == "quit") {
				quit_requested = true;
				break;
			}
			if (op == "cancel" || op == "unload") {
				continue;
			}

			if (!has_valid_id) {
				responder.malformed(id, op, "request has no non-negative integer id");
				continue;
			}
			if (op == "say" || op == "clone") {
				responder.unavailable(id, op);
			} else {
				responder.malformed(id, op, "unknown op: " + op);
			}
		}
		responder.bye();
		log << (quit_requested ? "quit requested" : "stdin reached EOF") << '\n';
		return 0;
	} catch (const std::exception &error) {
		log << "fatal: " << error.what() << '\n';
		std::cerr << error.what() << '\n';
		return 2;
	}
}

}  // namespace

int main(int argc, char **argv) {
	if (argc == 2) {
		const std::string flag(argv[1]);
		if (flag == "--version") {
			std::cout << "godot-pet-tts-helper " << kVersion << '\n';
			return 0;
		}
		if (flag == "--protocol-version") {
			std::cout << kProtocolVersion << '\n';
			return 0;
		}
		if (flag == "--self-test") {
			if (!internal_self_test()) {
				std::cerr << "internal JSON self-test failed\n";
				return 1;
			}
			std::cout << "{\"ok\":true,\"protocol\":1,\"engine\":\"unavailable\"}\n";
			return 0;
		}
	}

	Options options;
	std::string error;
	if (!parse_options(argc, argv, options, error)) {
		std::cerr << error << '\n';
		return 2;
	}
	return run(options);
}
