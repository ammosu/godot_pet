#include "engine_api.h"

// std::all_of, std::min and std::max. Only the first one actually needs naming
// here: libstdc++ reaches min/max through <bits/stl_algobase.h>, which every
// container header drags in, while all_of lives in <bits/stl_algo.h>, which
// none of them do. So a build can be one standard library away from failing on
// a line nobody touched — measured, GCC 13.3 refuses what clang accepted.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>
#else
#error "The native TTS helper currently requires POSIX file and pipe semantics"
#endif

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
		send("{\"event\":\"ready\",\"protocol\":1,\"engine\":\"" +
				escape_json(compiled_engine_name()) + "\"}");
	}

	void audio(std::int64_t id, const std::string &path, std::int32_t rate,
			std::size_t samples, std::int64_t milliseconds) {
		std::ostringstream event;
		event << "{\"event\":\"audio\",\"id\":" << id
			  << ",\"path\":\"" << escape_json(path)
			  << "\",\"rate\":" << rate
			  << ",\"samples\":" << samples
			  << ",\"ms\":" << milliseconds << "}";
		send(event.str());
	}

	void cloned(std::int64_t id, const std::string &path, std::size_t dimensions) {
		std::ostringstream event;
		event << "{\"event\":\"cloned\",\"id\":" << id
			  << ",\"path\":\"" << escape_json(path)
			  << "\",\"dims\":" << dimensions << "}";
		send(event.str());
	}

	void error(std::int64_t id, const std::string &op, const std::string &code,
			const std::string &message) {
		std::ostringstream event;
		event << "{\"event\":\"error\",\"id\":" << id
			  << ",\"op\":\"" << escape_json(op)
			  << "\",\"code\":\"" << escape_json(code)
			  << "\",\"message\":\"" << escape_json(message) << "\"}";
		send(event.str());
	}

	void malformed(std::int64_t id, const std::string &op, const std::string &message) {
		error(id, op, "malformed_request", message);
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

enum class WorkKind { Say, Clone, Unload, Malformed, Quit };

struct WorkItem {
	WorkKind kind = WorkKind::Malformed;
	std::int64_t id = 0;
	std::string op = "request";
	std::string text;
	std::string language;
	std::string voice;
	std::string wav;
	std::string output;
	std::string message;
};

class WorkQueue {
public:
	void push(WorkItem item) {
		{
			std::lock_guard<std::mutex> lock(mutex_);
			items_.push_back(std::move(item));
		}
		changed_.notify_one();
	}

	bool pop_for(WorkItem &item, std::chrono::milliseconds timeout) {
		std::unique_lock<std::mutex> lock(mutex_);
		if (!changed_.wait_for(lock, timeout, [this] { return !items_.empty(); })) {
			return false;
		}
		item = std::move(items_.front());
		items_.pop_front();
		return true;
	}

private:
	std::mutex mutex_;
	std::condition_variable changed_;
	std::deque<WorkItem> items_;
};

std::string string_member(
		const JsonValue &object, const std::string &key, const std::string &fallback = "") {
	const JsonValue *value = member(object, key);
	return value != nullptr && value->type == JsonValue::Type::String
			? value->text : fallback;
}

bool accept_request_line(const std::string &line, WorkQueue &queue,
		std::atomic<std::int64_t> &cancel_up_to, std::int64_t &last_say_id) {
	if (line.find_first_not_of(" \t\r\n") == std::string::npos) {
		return true;
	}

	JsonValue request;
	std::string parse_error;
	if (!JsonParser(line).parse(request, parse_error) ||
			request.type != JsonValue::Type::Object) {
		WorkItem malformed;
		malformed.message = parse_error.empty()
				? "request must be a JSON object" : parse_error;
		queue.push(std::move(malformed));
		return true;
	}

	WorkItem item;
	const JsonValue *id_value = member(request, "id");
	const bool has_valid_id = id_value != nullptr &&
			integer_value(*id_value, item.id) && item.id >= 0;
	if (!has_valid_id) {
		item.id = 0;
	}
	const JsonValue *op_value = member(request, "op");
	if (op_value == nullptr || op_value->type != JsonValue::Type::String ||
			op_value->text.empty()) {
		item.message = "request has no non-empty string op";
		queue.push(std::move(item));
		return true;
	}
	item.op = op_value->text;
	if (item.op == "cancel") {
		cancel_up_to.store(last_say_id, std::memory_order_release);
		return true;
	}
	if (item.op == "quit") {
		item.kind = WorkKind::Quit;
		queue.push(std::move(item));
		return false;
	}
	if (item.op == "unload") {
		item.kind = WorkKind::Unload;
		queue.push(std::move(item));
		return true;
	}
	if (!has_valid_id) {
		item.message = "request has no non-negative integer id";
		queue.push(std::move(item));
		return true;
	}
	if (item.op == "say") {
		item.kind = WorkKind::Say;
		item.text = string_member(request, "text");
		item.language = string_member(request, "lang", "zh");
		item.voice = string_member(request, "voice");
		last_say_id = std::max(last_say_id, item.id);
		queue.push(std::move(item));
		return true;
	}
	if (item.op == "clone") {
		item.kind = WorkKind::Clone;
		item.wav = string_member(request, "wav");
		item.output = string_member(request, "out");
		queue.push(std::move(item));
		return true;
	}
	item.message = "unknown op: " + item.op;
	queue.push(std::move(item));
	return true;
}

void read_requests(WorkQueue &queue, std::atomic<std::int64_t> &cancel_up_to,
		std::atomic<bool> &stop_requested) noexcept {
	bool enqueue_quit = true;
	try {
		std::int64_t last_say_id = -1;
		std::string pending;
		char buffer[4096];
		while (!stop_requested.load(std::memory_order_acquire)) {
			struct pollfd input = {};
			input.fd = STDIN_FILENO;
			input.events = POLLIN;
			const int poll_result = poll(&input, 1, 50);
			if (poll_result < 0) {
				if (errno == EINTR) {
					continue;
				}
				throw std::runtime_error(
						"cannot poll request input: " + std::string(std::strerror(errno)));
			}
			if (poll_result == 0) {
				continue;
			}
			if ((input.revents & (POLLIN | POLLHUP)) == 0) {
				if ((input.revents & (POLLERR | POLLNVAL)) != 0) {
					throw std::runtime_error("request input became unavailable");
				}
				continue;
			}
			const ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
			if (count < 0) {
				if (errno == EINTR) {
					continue;
				}
				throw std::runtime_error(
						"cannot read request input: " + std::string(std::strerror(errno)));
			}
			if (count == 0) {
				if (!pending.empty()) {
					enqueue_quit = accept_request_line(
							pending, queue, cancel_up_to, last_say_id);
				}
				break;
			}
			pending.append(buffer, static_cast<std::size_t>(count));
			std::size_t newline = 0;
			while ((newline = pending.find('\n')) != std::string::npos) {
				const std::string line = pending.substr(0, newline);
				pending.erase(0, newline + 1);
				if (!accept_request_line(line, queue, cancel_up_to, last_say_id)) {
					enqueue_quit = false;
					return;
				}
			}
		}
	} catch (const std::exception &error) {
		try {
			WorkItem malformed;
			malformed.message = std::string("request input failed: ") + error.what();
			queue.push(std::move(malformed));
		} catch (...) {
			enqueue_quit = false;
		}
	} catch (...) {
		try {
			WorkItem malformed;
			malformed.message = "request input failed with an unknown exception";
			queue.push(std::move(malformed));
		} catch (...) {
			enqueue_quit = false;
		}
	}
	if (enqueue_quit && !stop_requested.load(std::memory_order_acquire)) {
		try {
			WorkItem eof;
			eof.kind = WorkKind::Quit;
			eof.op = "quit";
			queue.push(std::move(eof));
		} catch (...) {
			// The process is already out of memory; the owning guard still joins us.
		}
	}
}

class ReaderGuard {
public:
	ReaderGuard(WorkQueue &queue, std::atomic<std::int64_t> &cancel_up_to,
			std::atomic<bool> &stop_requested)
		: stop_requested_(stop_requested),
		  thread_(read_requests, std::ref(queue), std::ref(cancel_up_to),
				  std::ref(stop_requested)) {}

	ReaderGuard(const ReaderGuard &) = delete;
	ReaderGuard &operator=(const ReaderGuard &) = delete;

	~ReaderGuard() {
		stop_and_join();
	}

	void stop_and_join() noexcept {
		stop_requested_.store(true, std::memory_order_release);
		if (thread_.joinable()) {
			thread_.join();
		}
	}

private:
	std::atomic<bool> &stop_requested_;
	std::thread thread_;
};

std::int32_t language_id(const std::string &language) {
	static const std::map<std::string, std::int32_t> languages = {
		{"en", 2050}, {"ru", 2069}, {"zh", 2055}, {"ja", 2058}, {"ko", 2064},
		{"de", 2053}, {"fr", 2061}, {"es", 2054}, {"it", 2070}, {"pt", 2071},
	};
	const auto found = languages.find(language);
	return found == languages.end() ? languages.at("zh") : found->second;
}

const char *engine_error_code() {
	return std::string(compiled_engine_name()) == "unavailable"
			? "engine_unavailable" : "engine_error";
}

std::uint16_t read_u16(const unsigned char *bytes) {
	return static_cast<std::uint16_t>(
			bytes[0] | (static_cast<std::uint16_t>(bytes[1]) << 8));
}

std::uint32_t read_u32(const unsigned char *bytes) {
	return static_cast<std::uint32_t>(bytes[0]) |
			(static_cast<std::uint32_t>(bytes[1]) << 8) |
			(static_cast<std::uint32_t>(bytes[2]) << 16) |
			(static_cast<std::uint32_t>(bytes[3]) << 24);
}

bool target_is_symlink(const std::filesystem::path &target, std::string &error) {
	struct stat status = {};
	if (lstat(target.c_str(), &status) == 0) {
		if (S_ISLNK(status.st_mode)) {
			error = "refusing symbolic-link output target: " + target.string();
			return true;
		}
		return false;
	}
	if (errno == ENOENT) {
		return false;
	}
	error = "cannot inspect output target " + target.string() + ": " +
			std::strerror(errno);
	return true;
}

class TemporaryOutput {
public:
	TemporaryOutput() = default;
	TemporaryOutput(const TemporaryOutput &) = delete;
	TemporaryOutput &operator=(const TemporaryOutput &) = delete;

	TemporaryOutput(TemporaryOutput &&other) noexcept
		: path_(std::move(other.path_)), handle_(other.handle_), committed_(other.committed_) {
		other.handle_ = nullptr;
		other.committed_ = true;
	}

	~TemporaryOutput() {
		if (handle_ != nullptr) {
			std::fclose(handle_);
		}
		if (!committed_ && !path_.empty()) {
			unlink(path_.c_str());
		}
	}

	static std::optional<TemporaryOutput> create(
			const std::filesystem::path &target, std::string &error) {
		if (target_is_symlink(target, error)) {
			return std::nullopt;
		}
		const std::filesystem::path directory =
				target.has_parent_path() ? target.parent_path() : std::filesystem::path(".");
		std::string pattern =
				(directory / ("." + target.filename().string() + ".part.XXXXXX")).string();
		std::vector<char> writable(pattern.begin(), pattern.end());
		writable.push_back('\0');
		const int descriptor = mkstemp(writable.data());
		if (descriptor < 0) {
			error = "cannot create temporary output beside " + target.string() + ": " +
					std::strerror(errno);
			return std::nullopt;
		}
		FILE *handle = fdopen(descriptor, "wb");
		if (handle == nullptr) {
			const int saved_errno = errno;
			close(descriptor);
			unlink(writable.data());
			error = "cannot open temporary output: " + std::string(std::strerror(saved_errno));
			return std::nullopt;
		}
		TemporaryOutput output;
		output.path_ = writable.data();
		output.handle_ = handle;
		output.committed_ = false;
		return output;
	}

	bool write(const void *bytes, std::size_t size, std::string &error) {
		if (size == 0) {
			return true;
		}
		if (handle_ == nullptr || std::fwrite(bytes, 1, size, handle_) != size) {
			error = "cannot write temporary output: " + std::string(std::strerror(errno));
			return false;
		}
		return true;
	}

	bool write_u16(std::uint16_t value, std::string &error) {
		const unsigned char bytes[] = {
			static_cast<unsigned char>(value & 0xff),
			static_cast<unsigned char>((value >> 8) & 0xff),
		};
		return write(bytes, sizeof(bytes), error);
	}

	bool write_u32(std::uint32_t value, std::string &error) {
		const unsigned char bytes[] = {
			static_cast<unsigned char>(value & 0xff),
			static_cast<unsigned char>((value >> 8) & 0xff),
			static_cast<unsigned char>((value >> 16) & 0xff),
			static_cast<unsigned char>((value >> 24) & 0xff),
		};
		return write(bytes, sizeof(bytes), error);
	}

	bool commit(const std::filesystem::path &target, std::string &error) {
		if (handle_ == nullptr) {
			error = "temporary output is already closed";
			return false;
		}
		if (std::fflush(handle_) != 0 || fsync(fileno(handle_)) != 0) {
			error = "cannot flush temporary output: " + std::string(std::strerror(errno));
			return false;
		}
		if (std::fclose(handle_) != 0) {
			handle_ = nullptr;
			error = "cannot close temporary output: " + std::string(std::strerror(errno));
			return false;
		}
		handle_ = nullptr;
		if (target_is_symlink(target, error)) {
			return false;
		}
		// POSIX rename replaces an existing non-directory atomically. It never
		// follows a destination symlink, and no pre-remove window is introduced.
		if (rename(path_.c_str(), target.c_str()) != 0) {
			error = "cannot install " + target.string() + ": " + std::strerror(errno);
			return false;
		}
		committed_ = true;
		return true;
	}

private:
	std::filesystem::path path_;
	FILE *handle_ = nullptr;
	bool committed_ = true;
};

bool write_pcm16_wav(const std::filesystem::path &path, const EngineAudio &audio,
		std::string &error) {
	if (audio.sample_rate <= 0 || audio.samples.empty() ||
			audio.samples.size() > (std::numeric_limits<std::uint32_t>::max() - 44) / 2) {
		error = "audio buffer is empty or too large";
		return false;
	}
	const std::uint64_t sample_rate = static_cast<std::uint64_t>(audio.sample_rate);
	const std::uint64_t byte_rate = sample_rate * sizeof(std::int16_t);
	constexpr std::uint64_t kMaximumReasonableSampleRate = 768000;
	if (sample_rate > kMaximumReasonableSampleRate ||
			sample_rate > std::numeric_limits<std::uint32_t>::max() ||
			byte_rate > std::numeric_limits<std::uint32_t>::max()) {
		error = "audio sample rate is out of WAV range";
		return false;
	}
	for (const float sample : audio.samples) {
		if (!std::isfinite(sample)) {
			error = "qwen returned non-finite audio samples";
			return false;
		}
	}
	const std::uint32_t data_bytes =
			static_cast<std::uint32_t>(audio.samples.size() * sizeof(std::int16_t));
	std::optional<TemporaryOutput> output = TemporaryOutput::create(path, error);
	if (!output.has_value()) {
		return false;
	}
	if (!output->write("RIFF", 4, error) ||
			!output->write_u32(36 + data_bytes, error) ||
			!output->write("WAVEfmt ", 8, error) ||
			!output->write_u32(16, error) ||
			!output->write_u16(1, error) ||
			!output->write_u16(1, error) ||
			!output->write_u32(static_cast<std::uint32_t>(sample_rate), error) ||
			!output->write_u32(static_cast<std::uint32_t>(byte_rate), error) ||
			!output->write_u16(2, error) ||
			!output->write_u16(16, error) ||
			!output->write("data", 4, error) ||
			!output->write_u32(data_bytes, error)) {
		return false;
	}
	for (const float sample : audio.samples) {
		const float clipped = std::max(-1.0f, std::min(1.0f, sample));
		const auto pcm = static_cast<std::int16_t>(
				std::lround(clipped < 0.0f ? clipped * 32768.0f : clipped * 32767.0f));
		if (!output->write_u16(static_cast<std::uint16_t>(pcm), error)) {
			return false;
		}
	}
	return output->commit(path, error);
}

bool write_embedding(const std::filesystem::path &path,
		const std::vector<float> &embedding, std::string &error) {
	if (embedding.empty() || embedding.size() > 4096) {
		error = "qwen returned an invalid speaker embedding";
		return false;
	}
	for (const float value : embedding) {
		if (!std::isfinite(value)) {
			error = "qwen returned a non-finite speaker embedding";
			return false;
		}
	}
	std::optional<TemporaryOutput> output = TemporaryOutput::create(path, error);
	if (!output.has_value()) {
		return false;
	}
	if (!output->write("Q3EM", 4, error) ||
			!output->write_u32(1, error) ||
			!output->write_u32(static_cast<std::uint32_t>(embedding.size()), error)) {
		return false;
	}
	for (const float value : embedding) {
		std::uint32_t bits = 0;
		static_assert(sizeof(bits) == sizeof(value), "float must be 32 bits");
		std::memcpy(&bits, &value, sizeof(bits));
		if (!output->write_u32(bits, error)) {
			return false;
		}
	}
	return output->commit(path, error);
}

bool read_embedding(const std::filesystem::path &path,
		std::vector<float> &embedding, std::string &error) {
	std::ifstream stream(path, std::ios::binary);
	if (!stream) {
		error = "cannot open speaker embedding: " + path.string();
		return false;
	}
	unsigned char header[12] = {};
	stream.read(reinterpret_cast<char *>(header), sizeof(header));
	if (stream.gcount() != static_cast<std::streamsize>(sizeof(header)) ||
			std::memcmp(header, "Q3EM", 4) != 0 || read_u32(header + 4) != 1) {
		error = "invalid speaker embedding header";
		return false;
	}
	const std::uint32_t dimensions = read_u32(header + 8);
	if (dimensions == 0 || dimensions > 4096) {
		error = "invalid speaker embedding dimensions";
		return false;
	}
	embedding.resize(dimensions);
	for (float &value : embedding) {
		unsigned char bytes[4] = {};
		stream.read(reinterpret_cast<char *>(bytes), sizeof(bytes));
		if (!stream) {
			error = "truncated speaker embedding";
			return false;
		}
		const std::uint32_t bits = read_u32(bytes);
		std::memcpy(&value, &bits, sizeof(value));
		if (!std::isfinite(value)) {
			error = "speaker embedding contains a non-finite value";
			return false;
		}
	}
	char trailing = '\0';
	if (stream.read(&trailing, 1)) {
		error = "speaker embedding has trailing bytes";
		return false;
	}
	if (!stream.eof()) {
		error = "cannot finish reading speaker embedding";
		return false;
	}
	return true;
}

std::optional<float> wav_peak(const std::filesystem::path &path) {
	std::ifstream stream(path, std::ios::binary);
	if (!stream) {
		return std::nullopt;
	}
	stream.seekg(0, std::ios::end);
	const std::streamoff actual_length = stream.tellg();
	if (actual_length < 12) {
		return std::nullopt;
	}
	stream.seekg(0, std::ios::beg);

	unsigned char riff[12] = {};
	stream.read(reinterpret_cast<char *>(riff), sizeof(riff));
	if (!stream || std::memcmp(riff, "RIFF", 4) != 0 ||
			std::memcmp(riff + 8, "WAVE", 4) != 0) {
		return std::nullopt;
	}
	const std::uint64_t riff_length =
			static_cast<std::uint64_t>(read_u32(riff + 4)) + 8;
	if (riff_length < sizeof(riff) ||
			riff_length > static_cast<std::uint64_t>(actual_length)) {
		return std::nullopt;
	}

	constexpr std::uint64_t kMaximumChunkBytes = 512ULL * 1024 * 1024;
	constexpr std::uint64_t kMaximumFormatBytes = 64ULL * 1024;
	bool pcm16 = false;
	float peak = 0.0f;
	std::uint64_t offset = sizeof(riff);
	while (offset + 8 <= riff_length) {
		unsigned char chunk[8] = {};
		stream.read(reinterpret_cast<char *>(chunk), sizeof(chunk));
		if (!stream) {
			return std::nullopt;
		}
		offset += sizeof(chunk);
		const std::uint64_t size = read_u32(chunk + 4);
		const std::uint64_t padded_size = size + (size & 1U);
		if (size > kMaximumChunkBytes || padded_size > riff_length - offset) {
			return std::nullopt;
		}
		if (std::memcmp(chunk, "fmt ", 4) == 0) {
			if (size < 16 || size > kMaximumFormatBytes) {
				return std::nullopt;
			}
			unsigned char format[16] = {};
			stream.read(reinterpret_cast<char *>(format), sizeof(format));
			if (!stream) {
				return std::nullopt;
			}
			pcm16 = read_u16(format) == 1 && read_u16(format + 14) == 16;
			stream.seekg(static_cast<std::streamoff>(
					padded_size - sizeof(format)), std::ios::cur);
		} else if (std::memcmp(chunk, "data", 4) == 0 && pcm16) {
			if ((size & 1U) != 0U) {
				return std::nullopt;
			}
			std::uint64_t remaining = size;
			unsigned char samples[4096] = {};
			while (remaining != 0) {
				const std::size_t count = static_cast<std::size_t>(
						std::min<std::uint64_t>(remaining, sizeof(samples)));
				stream.read(reinterpret_cast<char *>(samples),
						static_cast<std::streamsize>(count));
				if (!stream) {
					return std::nullopt;
				}
				for (std::size_t index = 0; index < count; index += 2) {
					const auto signed_sample =
							static_cast<std::int16_t>(read_u16(samples + index));
					peak = std::max(peak,
							std::abs(static_cast<float>(signed_sample)) / 32768.0f);
				}
				remaining -= count;
			}
			return peak;
		} else {
			stream.seekg(static_cast<std::streamoff>(padded_size), std::ios::cur);
		}
		if (!stream) {
			return std::nullopt;
		}
		offset += padded_size;
	}
	return std::nullopt;
}

void process_say(const WorkItem &item, const Options &options, EngineApi &engine,
		Responder &responder) {
	const bool only_json_whitespace = std::all_of(
			item.text.begin(), item.text.end(), [](unsigned char character) {
				return character == ' ' || character == '\t' ||
						character == '\r' || character == '\n';
			});
	if (only_json_whitespace) {
		responder.error(item.id, "say", "empty", "nothing to say");
		return;
	}
	std::string error;
	std::vector<float> embedding;
	const std::vector<float> *voice = nullptr;
	if (!item.voice.empty()) {
		if (!read_embedding(item.voice, embedding, error)) {
			responder.error(item.id, "say", "invalid_voice", error);
			return;
		}
		voice = &embedding;
	}

	EngineAudio audio;
	const auto started = std::chrono::steady_clock::now();
	bool synthesized = false;
	try {
		synthesized =
				engine.synthesize(item.text, language_id(item.language), voice, audio, error);
	} catch (const std::exception &exception) {
		responder.error(item.id, "say", "internal_error",
				std::string("TTS engine threw an exception: ") + exception.what());
		return;
	} catch (...) {
		responder.error(item.id, "say", "internal_error",
				"TTS engine threw an unknown exception");
		return;
	}
	if (!synthesized) {
		responder.error(item.id, "say", engine_error_code(), error);
		return;
	}
	const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - started).count();
	const std::filesystem::path path =
			std::filesystem::path(options.spool) / (std::to_string(item.id) + ".wav");
	if (!write_pcm16_wav(path, audio, error)) {
		responder.error(item.id, "say", "write_failed", error);
		return;
	}
	responder.audio(
			item.id, path.string(), audio.sample_rate, audio.samples.size(), milliseconds);
}

void process_clone(const WorkItem &item, EngineApi &engine, Responder &responder) {
	if (item.wav.empty() || item.output.empty()) {
		responder.error(item.id, "clone", "invalid_request",
				"clone requires wav and out paths");
		return;
	}
	const std::optional<float> peak = wav_peak(item.wav);
	if (peak.has_value() && *peak < 0.05f) {
		responder.error(item.id, "clone", "silent",
				"reference audio is almost silent");
		return;
	}

	std::vector<float> embedding;
	std::string error;
	bool extracted = false;
	try {
		extracted = engine.extract_embedding(item.wav, embedding, error);
	} catch (const std::exception &exception) {
		responder.error(item.id, "clone", "internal_error",
				std::string("TTS engine threw an exception: ") + exception.what());
		return;
	} catch (...) {
		responder.error(item.id, "clone", "internal_error",
				"TTS engine threw an unknown exception");
		return;
	}
	if (!extracted) {
		responder.error(item.id, "clone", engine_error_code(), error);
		return;
	}
	const std::filesystem::path output(item.output);
	std::error_code filesystem_error;
	if (output.has_parent_path()) {
		std::filesystem::create_directories(output.parent_path(), filesystem_error);
	}
	if (filesystem_error || !write_embedding(output, embedding, error)) {
		if (error.empty()) {
			error = "cannot create embedding directory: " + filesystem_error.message();
		}
		responder.error(item.id, "clone", "write_failed", error);
		return;
	}
	responder.cloned(item.id, output.string(), embedding.size());
}

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
	// qwen and ggml write diagnostics directly to the process streams. Redirect
	// both before the C API can be loaded, so an undrained pipe cannot fill and
	// block synthesis. Metadata modes return before run() and remain on stdout.
	if (std::freopen(options.log.c_str(), "a", stdout) == nullptr ||
			std::freopen(options.log.c_str(), "a", stderr) == nullptr) {
		return 2;
	}
	std::ofstream log(options.log, std::ios::app);
	if (!log) {
		std::cerr << "cannot open log file\n";
		return 2;
	}
	log << "native TTS helper " << kVersion << " started; engine="
		<< compiled_engine_name() << " models=" << options.models
		<< " threads=" << options.threads << " idle=" << options.idle << '\n';
	log.flush();

	try {
		Responder responder(options.output);
		responder.ready();

		WorkQueue queue;
		std::atomic<std::int64_t> cancel_up_to(-1);
		std::atomic<bool> stop_requested(false);
		std::unique_ptr<EngineApi> engine = create_engine(options.models, options.threads);
		ReaderGuard reader(queue, cancel_up_to, stop_requested);
		auto last_work = std::chrono::steady_clock::now();
		const auto idle = std::chrono::duration<double>(options.idle);
		bool finished = false;
		while (!finished) {
			WorkItem item;
			if (!queue.pop_for(item, std::chrono::milliseconds(50))) {
				try {
					if (engine->is_loaded() && options.idle >= 0.0 &&
							std::chrono::steady_clock::now() - last_work >= idle) {
						engine->unload();
						log << "engine unloaded after idle timeout\n";
						log.flush();
					}
				} catch (const std::exception &error) {
					log << "engine idle unload failed: " << error.what() << '\n';
					log.flush();
				} catch (...) {
					log << "engine idle unload failed with an unknown exception\n";
					log.flush();
				}
				continue;
			}

			switch (item.kind) {
				case WorkKind::Say:
					if (item.id <= cancel_up_to.load(std::memory_order_acquire)) {
						responder.error(item.id, "say", "cancelled", "dropped by cancel");
					} else {
						process_say(item, options, *engine, responder);
						last_work = std::chrono::steady_clock::now();
					}
					break;
				case WorkKind::Clone:
					process_clone(item, *engine, responder);
					last_work = std::chrono::steady_clock::now();
					break;
				case WorkKind::Unload:
					try {
						engine->unload();
					} catch (const std::exception &error) {
						log << "explicit engine unload failed: " << error.what() << '\n';
						log.flush();
					} catch (...) {
						log << "explicit engine unload failed with an unknown exception\n";
						log.flush();
					}
					break;
				case WorkKind::Malformed:
					responder.malformed(item.id, item.op, item.message);
					break;
				case WorkKind::Quit:
					finished = true;
					break;
			}
		}
		reader.stop_and_join();
		try {
			engine->unload();
		} catch (const std::exception &error) {
			log << "shutdown engine unload failed: " << error.what() << '\n';
		} catch (...) {
			log << "shutdown engine unload failed with an unknown exception\n";
		}
		responder.bye();
		log << "shutdown complete\n";
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
			std::cout << "{\"ok\":true,\"protocol\":1,\"engine\":\""
					  << escape_json(compiled_engine_name()) << "\"}\n";
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
