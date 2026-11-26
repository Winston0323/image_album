#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Drops debug-only framework chatter from stderr so real album errors stay
// visible: the Windows engine's accessibility-tree spam ("Failed to update
// ui::AXTree"), hit tests on render boxes mid-layout, and the MouseTracker
// "_debugDuringDeviceUpdate" assertion that fires when a pointer device
// update races a frame build. None crash the app and none appear in release
// builds. Every other stderr line is kept.
void SuppressAccessibilityTreeLog();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
