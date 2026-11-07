// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 the OpenRAC contributors
//
// iOS: the player's disc set up on the device (docs/port/IOS.md). A build made with Python in it
// (cmake/IOS.cmake, OPENRAC_IOS_PYTHON_XCFRAMEWORK) carries none of the game's data; on a start
// whose data folder has no game yet, this screen asks for the player's disc image and makes the
// data folder from it with the desktop's own scripts, in the Python linked into the program
// (ios/python.sh put it and the scripts in the bundle):
//
//   tools/extractor.py IMAGE --game <game> --proj-path data --extract --boot-only
//       iso_data/<game>/: SYSTEM.CNF, the boot executable, disc.iso (the image, linked when it is
//       on the same volume as the data folder, as it is in Documents, else copied)
//   editor/extract.py port data/iso_data/<game>/disc.iso data/port/<version> --anywhere --replace
//       the levels, one at a time (an app starts no process: extract.py's worker_pool)
//
// as the desktop launcher runs them (launcher/actions.json). The image is a .iso in the app's
// Documents folder (the Files app's On My iPhone → the game, or the Finder) or one the document
// picker opens (or OPENRAC_IOS_SETUP_IMAGE names, which starts it at once). The scripts' output
// goes to Documents/data/setup.log.

#include "program/program.h"

#if defined(OPENRAC_IOS) && defined(OPENRAC_IOS_SETUP)

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>

namespace fs = std::filesystem;

namespace {

// The data folder holds the game: the boot files, and every level (extract.py writes its
// levels-<format>.json stamp last).
bool ready(const fs::path& data) {
    std::error_code error;
    if (!fs::is_regular_file(data / "iso_data" / OPENRAC_IOS_GAME / "SYSTEM.CNF", error)) {
        return false;
    }
    for (const fs::directory_entry& entry :
         fs::directory_iterator(data / "port" / OPENRAC_IOS_VERSION, error)) {
        const std::string name = entry.path().filename().string();
        if (name.starts_with("levels-") && name.ends_with(".json")) {
            return true;
        }
    }
    return false;
}

// What the scripts do, in Python: each run as its file's __main__, its exit status kept. The
// boot files' build (iso_data/<game>/buildinfo.json) must be this program's version: the
// extractor takes any version of the game.
constexpr const char* kSetup = R"PY(
import os, runpy, sys, json, traceback
log = open(LOG, "w", buffering=1, encoding="utf-8", errors="replace")
sys.stdout = sys.stderr = log

def run(path, argv):
    sys.argv = argv
    try:
        runpy.run_path(path, run_name="__main__")
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except BaseException:
        traceback.print_exc()
        return 1
    return 0

def setup():
    os.chdir(DATA)
    code = run(SCRIPTS + "/tools/extractor.py", ["extractor.py", IMAGE, "--game", GAME,
               "--proj-path", DATA, "--extract", "--boot-only"])
    if code != 0:
        return code
    with open(os.path.join(DATA, "iso_data", GAME, "buildinfo.json")) as f:
        builds = [b.get("version") for b in json.load(f)]
    if GAME + "/" + VERSION not in builds:
        print(f"setup-error: this disc is {', '.join(map(str, builds))}; this app plays {GAME}/{VERSION}")
        return 2
    disc = os.path.join(DATA, "iso_data", GAME, "disc.iso")
    return run(SCRIPTS + "/editor/extract.py", ["extract.py", "port", disc,
               os.path.join(DATA, "port", VERSION), "--anywhere", "--replace", "--jobs", "1"])

status = setup()
log.flush()
sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__
log.close()
)PY";

std::once_flag g_python_started;

// The interpreter, isolated from the environment: its home the bundle's python/, its modules the
// standard library and OpenRAC's scripts' folders. Started once; each setup runs in it again.
bool start_python(const fs::path& bundle) {
    static bool started = false;
    std::call_once(g_python_started, [&] {
        const fs::path home = bundle / "python";
        const fs::path scripts = home / "openrac";
        fs::path stdlib;
        std::error_code error;
        for (const fs::directory_entry& entry : fs::directory_iterator(home / "lib", error)) {
            if (entry.path().filename().string().starts_with("python3.")) {
                stdlib = entry.path();
            }
        }
        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.write_bytecode = 0;
        config.buffered_stdio = 0;
        config.install_signal_handlers = 0;
        config.module_search_paths_set = 1;
        bool ok = !stdlib.empty()
                  && !PyStatus_Exception(PyConfig_SetBytesString(&config, &config.home, home.c_str()));
        for (const fs::path& path : {stdlib, stdlib / "lib-dynload", scripts / "editor", scripts / "tools"}) {
            wchar_t* wide = ok ? Py_DecodeLocale(path.c_str(), nullptr) : nullptr;
            ok = wide != nullptr
                 && !PyStatus_Exception(PyWideStringList_Append(&config.module_search_paths, wide));
            PyMem_RawFree(wide);
        }
        ok = ok && !PyStatus_Exception(Py_InitializeFromConfig(&config));
        PyConfig_Clear(&config);
        if (ok) {
            // The GIL let go: each setup takes it on its own thread.
            PyEval_SaveThread();
        }
        started = ok;
    });
    return started;
}

void set_string(PyObject* globals, const char* name, const std::string& value) {
    PyObject* object = PyUnicode_DecodeFSDefault(value.c_str());
    PyDict_SetItemString(globals, name, object);
    Py_XDECREF(object);
}

// Runs the setup from IMAGE into DATA; the scripts' exit status (0: the data folder is whole).
int run_setup(const fs::path& bundle, const fs::path& image, const fs::path& data, const fs::path& log) {
    if (!start_python(bundle)) {
        std::ofstream(log) << "setup-error: Python did not start\n";
        return 1;
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject* globals = PyDict_New();
    PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
    set_string(globals, "LOG", log.string());
    set_string(globals, "DATA", data.string());
    set_string(globals, "IMAGE", image.string());
    set_string(globals, "SCRIPTS", (bundle / "python" / "openrac").string());
    set_string(globals, "GAME", OPENRAC_IOS_GAME);
    set_string(globals, "VERSION", OPENRAC_IOS_VERSION);
    int status = 1;
    if (PyObject* result = PyRun_String(kSetup, Py_file_input, globals, globals)) {
        Py_DECREF(result);
        if (PyObject* value = PyDict_GetItemString(globals, "status"); value && PyLong_Check(value)) {
            status = static_cast<int>(PyLong_AsLong(value));
        }
    } else {
        PyErr_Print();
    }
    Py_DECREF(globals);
    // What the levels left behind, given back before the game starts.
    PyRun_SimpleString("import gc; gc.collect()");
    PyGILState_Release(gil);
    return status;
}

// The last line of the log that says something to the player: its progress ("openrac-progress:
// read 3/21") while it runs, its error when it stops.
std::string last_line(const fs::path& log, const char* prefix) {
    std::ifstream file(log);
    std::string line;
    std::string found;
    while (std::getline(file, line)) {
        if (line.starts_with(prefix)) {
            found = line.substr(std::char_traits<char>::length(prefix));
        }
    }
    return found;
}

std::string failure(const fs::path& log) {
    std::string reason = last_line(log, "setup-error: ");
    if (reason.empty()) {
        reason = last_line(log, "error ");  // the extractor's "error 4001: ..."
        if (!reason.empty()) {
            reason = "error " + reason;
        }
    }
    if (reason.empty()) {
        // Whatever came last: a traceback's exception.
        std::ifstream file(log);
        for (std::string line; std::getline(file, line);) {
            if (!line.empty()) {
                reason = line;
            }
        }
    }
    return reason;
}

// One setup's run: its thread writes, the screen reads.
struct Run {
    std::atomic<bool> finished = false;
    std::atomic<int> status = 1;
};

}  // namespace

// ---- the screen ----

@interface OpenracSetupController : UIViewController <UIDocumentPickerDelegate> {
  @public
    std::atomic<bool>* done;
    fs::path data;
    fs::path documents;
    std::shared_ptr<Run> run;
}
@property(nonatomic) UILabel* message;
@property(nonatomic) UILabel* status;
@property(nonatomic) UIProgressView* progress;
@property(nonatomic) UIButton* found;
@property(nonatomic) UIButton* choose;
@property(nonatomic, copy) NSURL* foundImage;
@property(nonatomic) NSTimer* timer;
@end

@implementation OpenracSetupController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIButton*)button:(UIButtonConfiguration*)style title:(NSString*)title action:(SEL)action {
    style.title = title;
    style.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    UIButton* button = [UIButton buttonWithConfiguration:style primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel* title = [[UILabel alloc] init];
    title.text = @OPENRAC_GAME_TITLE;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.adjustsFontForContentSizeCategory = YES;

    self.message = [[UILabel alloc] init];
    self.message.numberOfLines = 0;
    self.message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.message.adjustsFontForContentSizeCategory = YES;
    self.message.textColor = UIColor.secondaryLabelColor;

    self.status = [[UILabel alloc] init];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.status.adjustsFontForContentSizeCategory = YES;

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

    self.found = [self button:[UIButtonConfiguration filledButtonConfiguration]
                        title:@""
                       action:@selector(useFound)];
    self.choose = [self button:[UIButtonConfiguration tintedButtonConfiguration]
                         title:@"Choose disc image…"
                        action:@selector(pick)];

    UIStackView* buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ self.found, self.choose ]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12;

    UIStackView* stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[ title, self.message, self.status, self.progress, buttons ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView* scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [self.view addSubview:scroll];
    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide* content = scroll.contentLayoutGuide;
    NSLayoutConstraint* centred = [stack.centerYAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerYAnchor];
    centred.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-32],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:16],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-16],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-64],
        [self.progress.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        centred,
    ]];

    [self idle:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(cameBack)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
}

- (BOOL)running {
    return run != nullptr;
}

// A .iso in the app's Documents folder, which the player may have put there meanwhile.
- (NSURL*)imageInDocuments {
    std::error_code error;
    for (const fs::directory_entry& entry : fs::directory_iterator(documents, error)) {
        std::string extension = entry.path().extension().string();
        for (char& c : extension) {
            c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        if (extension == ".iso" && entry.is_regular_file(error)) {
            return [NSURL fileURLWithPath:@(entry.path().c_str())];
        }
    }
    return nil;
}

- (void)cameBack {
    if (!self.running) {
        [self idle:self.status.textColor == UIColor.systemRedColor ? self.status.text : nil];
    }
}

// Waiting for the disc; REASON is why the last try stopped.
- (void)idle:(NSString*)reason {
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    self.message.text =
        @"OpenRAC needs your own copy of the game: a disc image (.iso) of " @OPENRAC_GAME_TITLE
        @", made from your disc. It is set up once, here on the device: that takes about 5 GB and "
        @"up to half an hour. Put the .iso in Files → On My iPhone → " @OPENRAC_GAME_TITLE
        @" (or copy it there from a computer with the Finder), or choose it from anywhere in Files.";
    self.status.text = reason;
    self.status.textColor = reason != nil ? UIColor.systemRedColor : UIColor.labelColor;
    self.status.hidden = reason == nil;
    self.progress.hidden = YES;
    self.foundImage = [self imageInDocuments];
    self.found.hidden = self.foundImage == nil;
    if (self.foundImage != nil) {
        UIButtonConfiguration* style = self.found.configuration;
        style.title = [NSString stringWithFormat:@"Use %@", self.foundImage.lastPathComponent];
        self.found.configuration = style;
    }
    self.choose.hidden = NO;
}

- (void)useFound {
    if (self.foundImage != nil) {
        [self start:self.foundImage scoped:NO];
    }
}

- (void)pick {
    NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypeDiskImage];
    if (UTType* iso = [UTType typeWithFilenameExtension:@"iso"]) {
        [types addObject:iso];
    }
    [types addObject:UTTypeData];
    // Opened where it is, not copied first: the image is 4 GB, and the extractor copies it once
    // into the data folder (or links it, from Documents).
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count > 0) {
        [self start:urls.firstObject scoped:YES];
    }
}

- (void)start:(NSURL*)image scoped:(BOOL)scoped {
    if (self.running) {
        return;
    }
    if (![image.pathExtension.lowercaseString isEqualToString:@"iso"]) {
        [self idle:@"That is not a disc image: choose a file whose name ends in .iso."];
        return;
    }
    self.found.hidden = YES;
    self.choose.hidden = YES;
    self.progress.hidden = NO;
    self.progress.progress = 0;
    self.status.hidden = NO;
    self.status.textColor = UIColor.labelColor;
    self.status.text = @"Reading the disc…";
    self.message.text = @"Keep OpenRAC on the screen until this is done; the screen stays on meanwhile. "
                        @"If it goes to the background, it carries on when it is back.";
    // A locked device suspends the app: the screen stays on until the setup ends.
    UIApplication.sharedApplication.idleTimerDisabled = YES;

    run = std::make_shared<Run>();
    std::shared_ptr<Run> shared = run;
    const fs::path to = data;
    const fs::path log = data / "setup.log";
    const fs::path bundle = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
    std::thread([image, scoped, to, log, bundle, shared] {
        const BOOL accessing = scoped && [image startAccessingSecurityScopedResource];
        // A file of iCloud Drive or another provider is downloaded first.
        NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError* error = nil;
        [coordinator coordinateReadingItemAtURL:image
                                        options:NSFileCoordinatorReadingWithoutChanges
                                          error:&error
                                     byAccessor:^(NSURL* url) {
                                       shared->status = run_setup(bundle, url.fileSystemRepresentation, to, log);
                                     }];
        if (error != nil) {
            std::ofstream(log, std::ios::app) << "setup-error: the image could not be opened: "
                                              << error.localizedDescription.UTF8String << "\n";
        }
        if (accessing) {
            [image stopAccessingSecurityScopedResource];
        }
        shared->finished = true;
    }).detach();
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                  target:self
                                                selector:@selector(follow)
                                                userInfo:nil
                                                 repeats:YES];
}

// The setup's log, followed while it runs.
- (void)follow {
    const fs::path log = data / "setup.log";
    if (!run->finished) {
        const std::string line = last_line(log, "openrac-progress: ");
        int made = 0;
        int total = 0;
        if (std::sscanf(line.c_str(), "%*s %d/%d", &made, &total) == 2 && total > 0) {
            self.status.text = [NSString stringWithFormat:@"Making the levels: %d of %d", made, total];
            self.progress.progress = static_cast<float>(made) / static_cast<float>(total);
        }
        return;
    }
    [self.timer invalidate];
    self.timer = nil;
    const int status = run->status;
    run = nullptr;
    if (ready(data)) {
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        done->store(true);
        return;
    }
    const std::string reason = failure(log);
    [self idle:[NSString stringWithFormat:@"The setup stopped (%d): %s", status, reason.c_str()]];
}

@end

namespace openrac::program {

void ios_setup(const fs::path& documents, const fs::path& data) {
    if (ready(data)) {
        return;
    }
    std::atomic<bool> done = false;
    UIWindow* window = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
            break;
        }
    }
    if (window == nil) {
        window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    OpenracSetupController* controller = [[OpenracSetupController alloc] init];
    controller->done = &done;
    controller->data = data;
    controller->documents = documents;
    window.rootViewController = controller;
    window.windowLevel = UIWindowLevelNormal + 1;
    [window makeKeyAndVisible];
    // OPENRAC_IOS_SETUP_IMAGE: the setup started with that image, nobody at the screen (a simulator's
    // test: SIMCTL_CHILD_OPENRAC_IOS_SETUP_IMAGE). Read here, before env.h's snapshot.
    if (const char* image = std::getenv("OPENRAC_IOS_SETUP_IMAGE"); image != nullptr && *image != 0) {
        [controller loadViewIfNeeded];
        [controller start:[NSURL fileURLWithPath:@(image)] scoped:NO];
    }
    // The main thread serves UIKit meanwhile, as SDL's own loop does after.
    while (!done) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    window.hidden = YES;
    window.rootViewController = nil;
}

}  // namespace openrac::program

#endif
