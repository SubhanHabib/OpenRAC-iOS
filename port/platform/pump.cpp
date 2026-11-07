// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 the OpenRAC contributors

#include "platform/pump.h"

#include <SDL3/SDL.h>

#include <deque>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#include "common/env.h"
#include "common/log.h"

namespace openrac::platform {

#if defined(_WIN32)

namespace {

// The program's stack: what the main thread's is by default.
constexpr SIZE_T kProgramStack = 8u * 1024 * 1024;

struct Pump {
    LPVOID pump_fiber = nullptr;     // the thread itself: reads the system's events
    LPVOID program_fiber = nullptr;  // the program
    DWORD thread = 0;
    int (*program)(void*) = nullptr;
    void* argument = nullptr;
    int result = 0;
    bool done = false;
    bool pumping = false;  // the pump is inside SDL_PumpEvents
    // The program was handed to from inside the pump (the system holds it in its loop), and when.
    bool held = false;
    Uint64 entered = 0;
} pump;

// While the system holds the pump, the program keeps its turn for at least this long: SDL's timer
// in that loop comes every 10 ms, so a turn of that length finds the next one due as it ends, and
// the loop never sits waiting for the timer while the game's tick is due.
constexpr Uint64 kHeldTurnNs = 10'000'000;

void CALLBACK program_entry(void*) {
    pump.result = pump.program(pump.argument);
    pump.done = true;
    SwitchToFiber(pump.pump_fiber);
}

// Called by SDL as each event is queued. An expose event that arrives while the pump is inside
// SDL_PumpEvents is the system's loop (or an uncovered window) asking for a frame: the program
// gets its turn, and comes back here when it next reads its events.
bool SDLCALL on_event(void*, SDL_Event* event) {
    if (event->type == SDL_EVENT_WINDOW_EXPOSED && pump.pumping && !pump.done && GetCurrentThreadId() == pump.thread
        && GetCurrentFiber() == pump.pump_fiber) {
        pump.held = true;
        pump.entered = SDL_GetTicksNS();
        SwitchToFiber(pump.program_fiber);
        pump.held = false;
    }
    return true;
}

}  // namespace

int run_pumped(int (*program)(void*), void* argument) {
    pump = Pump{};
    pump.program = program;
    pump.argument = argument;
    pump.thread = GetCurrentThreadId();
    // OPENRAC_NO_PUMP_FIBER: the program and the pump in one loop, as before (for comparing).
    if (env::flag(env::Var::NoPumpFiber)) {
        return program(argument);
    }
    // The floating-point state is each fiber's own: the game sets rounding modes.
    pump.pump_fiber = IsThreadAFiber() ? GetCurrentFiber() : ConvertThreadToFiberEx(nullptr, FIBER_FLAG_FLOAT_SWITCH);
    if (pump.pump_fiber != nullptr) {
        pump.program_fiber = CreateFiberEx(0, kProgramStack, FIBER_FLAG_FLOAT_SWITCH, program_entry, nullptr);
    }
    if (pump.program_fiber == nullptr) {
        log::warn("no fiber for the game (error {}): the picture will stand still while the window is dragged",
                  static_cast<unsigned long>(GetLastError()));
        pump.pump_fiber = nullptr;
        return program(argument);
    }
    SDL_AddEventWatch(on_event, nullptr);
    while (!pump.done) {
        pump.pumping = true;
        SDL_PumpEvents();
        pump.pumping = false;
        if (!pump.done) {
            SwitchToFiber(pump.program_fiber);
        }
    }
    SDL_RemoveEventWatch(on_event, nullptr);
    DeleteFiber(pump.program_fiber);
    pump.program_fiber = nullptr;
    return pump.result;
}

bool poll_event(SDL_Event& event) {
    if (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {
        return true;
    }
    if (pump.program_fiber != nullptr && GetCurrentThreadId() == pump.thread && GetCurrentFiber() == pump.program_fiber) {
        if (pump.held && SDL_GetTicksNS() - pump.entered < kHeldTurnNs) {
            return false;  // the turn is not over: the pump reads the system's events after it
        }
        SwitchToFiber(pump.pump_fiber);  // the pump reads the system's events and hands back
    } else {
        SDL_PumpEvents();
    }
    return SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0;
}

#else

int run_pumped(int (*program)(void*), void* argument) {
    return program(argument);
}

#if defined(OPENRAC_IOS)

namespace {

// iOS: an app in the background may not use the GPU (its command buffers fail and Metal's device is
// lost), and it is suspended a few seconds after it leaves the screen. SDL gives the events that
// say so (SDL_EVENT_WILL_ENTER_BACKGROUND and the three others) to its event watchers only, inside
// UIKit's call, and never queues them: watch() keeps them for the program. The program's next read
// of its events after the app leaves waits here, reading the system's (SDL_WaitEventTimeout runs
// UIKit's loop), until the app is in front again; what arrived meanwhile then goes to the program
// in order. UIKit calls on the main thread, the one that reads the events.
bool leaving = false;
bool in_front = true;
std::deque<SDL_Event> arrived;

bool SDLCALL watch(void*, SDL_Event* event) {
    switch (event->type) {
        case SDL_EVENT_WILL_ENTER_BACKGROUND:
            leaving = true;
            in_front = false;
            break;
        case SDL_EVENT_DID_ENTER_FOREGROUND:
            in_front = true;
            break;
        case SDL_EVENT_DID_ENTER_BACKGROUND:
        case SDL_EVENT_WILL_ENTER_FOREGROUND:
            break;
        default:
            return true;
    }
    arrived.push_back(*event);
    return true;
}

void wait_for_foreground() {
    log::info("ios: leaving the screen, the game waits");
    SDL_Event event;
    while (!in_front) {
        if (SDL_WaitEventTimeout(&event, 100)) {
            arrived.push_back(event);
        }
    }
    log::info("ios: back in front, after {} events", arrived.size());
}

}  // namespace

bool poll_event(SDL_Event& event) {
    [[maybe_unused]] static const bool watching = SDL_AddEventWatch(watch, nullptr);
    if (leaving) {
        leaving = false;
        wait_for_foreground();
    }
    if (arrived.empty()) {
        return SDL_PollEvent(&event);
    }
    event = arrived.front();
    arrived.pop_front();
    return true;
}

#else

bool poll_event(SDL_Event& event) {
    return SDL_PollEvent(&event);
}

#endif

#endif

}  // namespace openrac::platform
