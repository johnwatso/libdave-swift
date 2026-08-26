#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "external_sender.h"

namespace {

std::string Hex(const std::vector<uint8_t>& bytes)
{
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(bytes.size() * 2);
    for (const auto byte : bytes) {
        result.push_back(digits[byte >> 4]);
        result.push_back(digits[byte & 0x0f]);
    }
    return result;
}

uint8_t Nibble(char value)
{
    if (value >= '0' && value <= '9') {
        return static_cast<uint8_t>(value - '0');
    }
    if (value >= 'a' && value <= 'f') {
        return static_cast<uint8_t>(value - 'a' + 10);
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<uint8_t>(value - 'A' + 10);
    }
    throw std::runtime_error("invalid hexadecimal input");
}

std::vector<uint8_t> Unhex(const std::string& value)
{
    if (value.size() % 2 != 0) {
        throw std::runtime_error("odd-length hexadecimal input");
    }
    std::vector<uint8_t> result;
    result.reserve(value.size() / 2);
    for (size_t index = 0; index < value.size(); index += 2) {
        result.push_back(static_cast<uint8_t>((Nibble(value[index]) << 4) | Nibble(value[index + 1])));
    }
    return result;
}

std::string ReadPayload(const char* expectedCommand)
{
    std::string line;
    if (!std::getline(std::cin, line)) {
        throw std::runtime_error(std::string("missing ") + expectedCommand + " command");
    }
    const std::string prefix = std::string(expectedCommand) + " ";
    if (line.rfind(prefix, 0) != 0) {
        throw std::runtime_error(std::string("expected ") + expectedCommand + " command");
    }
    return line.substr(prefix.size());
}

} // namespace

int main(int argc, char** argv)
{
    try {
        if (argc != 2) {
            throw std::runtime_error("usage: dave_external_sender_helper <group-id>");
        }
        const auto groupId = std::stoull(argv[1]);
        discord::dave::test::ExternalSender sender(daveMaxSupportedProtocolVersion(), groupId);

        std::cout << "EXTERNAL_SENDER " << Hex(sender.GetMarshalledExternalSender()) << std::endl;

        const auto keyPackage = Unhex(ReadPayload("KEY_PACKAGE"));
        std::cout << "PROPOSAL " << Hex(sender.ProposeAdd(0, keyPackage)) << std::endl;

        const auto commitWelcome = Unhex(ReadPayload("COMMIT_WELCOME"));
        const auto [commit, welcome] = sender.SplitCommitWelcome(commitWelcome);
        std::cout << "COMMIT " << Hex(commit) << std::endl;
        std::cout << "WELCOME " << Hex(welcome) << std::endl;

        const auto rekeyPackage = Unhex(ReadPayload("REKEY_PACKAGE"));
        std::cout << "REKEY_PROPOSAL " << Hex(sender.ProposeAdd(1, rekeyPackage)) << std::endl;

        const auto rekeyCommitWelcome = Unhex(ReadPayload("REKEY_COMMIT_WELCOME"));
        const auto [rekeyCommit, rekeyWelcome] = sender.SplitCommitWelcome(rekeyCommitWelcome);
        std::cout << "REKEY_COMMIT " << Hex(rekeyCommit) << std::endl;
        std::cout << "REKEY_WELCOME " << Hex(rekeyWelcome) << std::endl;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "ERROR " << error.what() << std::endl;
        return 1;
    }
}
