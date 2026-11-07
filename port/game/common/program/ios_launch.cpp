// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 the OpenRAC contributors
//
// iOS: the command line of a game started from the home screen, which has none (docs/port/IOS.md).
// The app's Documents folder, which the Files app and the Finder show (UIFileSharingEnabled), is
// where the player puts what the extractor made:
//
//   Documents/data/iso_data/<game>/<serial>, disc.iso   the game's data folder (--data)
//   Documents/data/port/<version>/                      the levels
//   Documents/args.txt                                  more arguments, one a line ("--level 3",
//                                                       an option and its value); a line
//                                                       "env NAME=value" sets a variable instead
//   Documents/data.aar                                  an Apple Archive of data folder entries,
//                                                       unpacked into Documents/data at the next
//                                                       start and then deleted
//
// The archive is how tools/build_ios.py --device sends the levels: a device takes files one
// request at a time, and the levels are thousands of small ones; one file goes at the network's
// speed.
//
// The cards and settings are in Documents/OpenRAC (options.cpp, data_home), the logs and crash
// reports in Documents/data. Arguments given to the program (xcrun simctl launch ... -- --level 3)
// come first and are kept; --data and --window are added when they are not among them.

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include "program/program.h"

#if defined(OPENRAC_IOS)

#include <fcntl.h>

#include <AppleArchive/AppleArchive.h>
#include <CoreFoundation/CoreFoundation.h>

namespace openrac::program {

namespace {

// Extracts the archive into the folder. False when it could not be read whole.
bool extract(const std::filesystem::path& archive, const std::filesystem::path& folder) {
    bool ok = false;
    AAByteStream file = AAFileStreamOpenWithPath(archive.c_str(), O_RDONLY, 0);
    AAByteStream decompressed =
        file != nullptr ? AADecompressionInputStreamOpen(file, 0, 0) : nullptr;
    AAArchiveStream entries =
        decompressed != nullptr
            ? AADecodeArchiveInputStreamOpen(decompressed, nullptr, nullptr, 0, 0)
            : nullptr;
    AAArchiveStream output = entries != nullptr
                                 ? AAExtractArchiveOutputStreamOpen(
                                       folder.c_str(), nullptr, nullptr, AA_FLAG_IGNORE_EPERM, 0
                                   )
                                 : nullptr;
    if (output != nullptr) {
        ok = AAArchiveStreamProcess(entries, output, nullptr, nullptr, 0, 0) >= 0;
        // The last files are written at the close.
        ok = AAArchiveStreamClose(output) >= 0 && ok;
    }
    if (entries != nullptr) {
        AAArchiveStreamClose(entries);
    }
    if (decompressed != nullptr) {
        AAByteStreamClose(decompressed);
    }
    if (file != nullptr) {
        AAByteStreamClose(file);
    }
    return ok;
}

// Documents/data.aar into the data folder, then the archive deleted; one that cannot be read is
// left for the player to see. The main thread keeps serving UIKit meanwhile: an app whose launch
// holds it for long is stopped by the system.
void unpack(const std::filesystem::path& archive, const std::filesystem::path& folder) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(archive, error)) {
        return;
    }
    std::fprintf(stderr, "Unpacking %s into %s\n", archive.c_str(), folder.c_str());
    std::atomic<bool> done = false;
    bool ok = false;
    std::thread worker([&] {
        ok = extract(archive, folder);
        done = true;
    });
    while (!done) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    worker.join();
    if (ok) {
        std::filesystem::remove(archive, error);
        std::fprintf(stderr, "Unpacked %s\n", archive.c_str());
    } else {
        std::fprintf(stderr, "Could not unpack %s: left as it is\n", archive.c_str());
    }
}

}  // namespace

void ios_arguments(int& argc, char**& argv) {
    static std::vector<std::string> args;
    static std::vector<char*> pointers;
    args.assign(argv, argv + argc);
    // Nothing of env.h yet: its snapshot is taken at the first read, after args.txt's variables.
    const char* home = std::getenv("HOME");
    const std::filesystem::path documents =
        std::filesystem::path(home != nullptr ? home : ".") / "Documents";
    const std::filesystem::path data = documents / "data";
    std::error_code ignored;
    std::filesystem::create_directories(data, ignored);
    unpack(documents / "data.aar", data);
#if defined(OPENRAC_IOS_SETUP)
    // A build without the game's data: the player's disc, set up here the first time.
    ios_setup(documents, data);
#endif

    std::ifstream extra(documents / "args.txt");
    for (std::string line; std::getline(extra, line);) {
        while (!line.empty()
               && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t')) {
            line.pop_back();
        }
        const std::size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos || line[start] == '#') {
            continue;
        }
        line.erase(0, start);
        if (line.starts_with("env ")) {
            const std::string assignment = line.substr(4);
            if (const std::size_t eq = assignment.find('='); eq != std::string::npos && eq > 0) {
                setenv(assignment.substr(0, eq).c_str(), assignment.substr(eq + 1).c_str(), 1);
            }
            continue;
        }
        // "--level 3": the option, then its value (which may have blanks, as a folder's name can).
        if (const std::size_t blank = line.find_first_of(" \t");
            line.starts_with("-") && blank != std::string::npos) {
            args.push_back(line.substr(0, blank));
            const std::size_t value = line.find_first_not_of(" \t", blank);
            args.push_back(line.substr(value));
            continue;
        }
        args.push_back(line);
    }

    bool has_data = false;
    bool has_window = false;
    for (const std::string& a : args) {
        has_data = has_data || a == "--data";
        has_window = has_window || a == "--window";
    }
    if (!has_data) {
        args.push_back("--data");
        args.push_back(data.string());
    }
    // A desktop's launcher asks for the window (Android's too): a game started from the home
    // screen always has one.
    if (!has_window) {
        args.push_back("--window");
    }

    pointers.clear();
    for (std::string& a : args) {
        pointers.push_back(a.data());
    }
    pointers.push_back(nullptr);
    argc = static_cast<int>(args.size());
    argv = pointers.data();
}

}  // namespace openrac::program

#endif
