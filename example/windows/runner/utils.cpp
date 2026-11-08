#include "utils.h"

#include <fcntl.h>
#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>
#include <string>
#include <thread>

namespace {

bool IsAccessibilityTreeNoise(const std::string& line) {
  return line.find("Failed to update ui::AXTree") != std::string::npos;
}

void ForwardStderr(HANDLE source, HANDLE destination) {
  std::string pending;
  char buffer[1024];
  DWORD read = 0;
  while (::ReadFile(source, buffer, sizeof(buffer), &read, nullptr) &&
         read > 0) {
    pending.append(buffer, buffer + read);
    size_t start = 0;
    while (true) {
      const size_t end = pending.find('\n', start);
      if (end == std::string::npos) {
        pending.erase(0, start);
        break;
      }
      const std::string line = pending.substr(start, end - start + 1);
      start = end + 1;
      if (IsAccessibilityTreeNoise(line)) {
        continue;
      }
      DWORD written = 0;
      ::WriteFile(destination, line.data(), static_cast<DWORD>(line.size()),
                  &written, nullptr);
    }
    if (pending.size() > 65536) {
      DWORD written = 0;
      ::WriteFile(destination, pending.data(),
                  static_cast<DWORD>(pending.size()), &written, nullptr);
      pending.clear();
    }
  }
  if (!pending.empty() && !IsAccessibilityTreeNoise(pending)) {
    DWORD written = 0;
    ::WriteFile(destination, pending.data(), static_cast<DWORD>(pending.size()),
                &written, nullptr);
  }
  ::CloseHandle(source);
  ::CloseHandle(destination);
}

}  // namespace

void SuppressAccessibilityTreeLog() {
  const int fd = _fileno(stderr);
  HANDLE current = ::GetStdHandle(STD_ERROR_HANDLE);
  if (fd < 0 || current == nullptr || current == INVALID_HANDLE_VALUE) {
    return;
  }

  HANDLE original = nullptr;
  if (!::DuplicateHandle(::GetCurrentProcess(), current, ::GetCurrentProcess(),
                         &original, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
    return;
  }

  SECURITY_ATTRIBUTES security = {};
  security.nLength = sizeof(security);
  security.bInheritHandle = FALSE;
  HANDLE read_end = nullptr;
  HANDLE write_end = nullptr;
  if (!::CreatePipe(&read_end, &write_end, &security, 1 << 16)) {
    ::CloseHandle(original);
    return;
  }

  // The C runtime owns write_end after this. A second handle is published as
  // the process stderr so both fprintf and GetStdHandle reach the filter.
  const int pipe_fd =
      _open_osfhandle(reinterpret_cast<intptr_t>(write_end), _O_WRONLY | _O_BINARY);
  if (pipe_fd == -1) {
    ::CloseHandle(read_end);
    ::CloseHandle(write_end);
    ::CloseHandle(original);
    return;
  }
  HANDLE published = nullptr;
  if (!::DuplicateHandle(::GetCurrentProcess(), write_end,
                         ::GetCurrentProcess(), &published, 0, FALSE,
                         DUPLICATE_SAME_ACCESS) ||
      _dup2(pipe_fd, fd) != 0) {
    _close(pipe_fd);
    ::CloseHandle(read_end);
    if (published != nullptr) {
      ::CloseHandle(published);
    }
    ::CloseHandle(original);
    return;
  }
  _close(pipe_fd);
  ::SetStdHandle(STD_ERROR_HANDLE, published);
  std::fflush(stderr);
  setvbuf(stderr, nullptr, _IONBF, 0);

  std::thread(ForwardStderr, read_end, original).detach();
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
