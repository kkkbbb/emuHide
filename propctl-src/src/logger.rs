use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// 全局 verbose 开关（由 --verbose 标志控制）
pub static VERBOSE: AtomicBool = AtomicBool::new(false);
static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

pub fn is_verbose() -> bool {
    VERBOSE.load(Ordering::Relaxed)
}

pub fn init_output_file(path: &str) -> std::io::Result<()> {
    let file = OpenOptions::new().create(true).write(true).truncate(true).open(path)?;
    let _ = LOG_FILE.set(Mutex::new(file));
    Ok(())
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn write_log_line(line: &str) {
    if let Some(file) = LOG_FILE.get() {
        let mut guard = file.lock().unwrap_or_else(|e| e.into_inner());
        let _ = writeln!(guard, "{}", strip_ansi(line));
        let _ = guard.flush();
    }
}

pub fn stdout_line(colored: &str, plain: &str) {
    println!("{}", colored);
    write_log_line(plain);
}

pub fn stderr_line(colored: &str, plain: &str) {
    eprintln!("{}", colored);
    write_log_line(plain);
}

/// ANSI 颜色常量
pub const RESET: &str = "\x1b[0m";
pub const BOLD: &str = "\x1b[1m";
pub const DIM: &str = "\x1b[2m";

pub const RED: &str = "\x1b[31m";
pub const GREEN: &str = "\x1b[32m";
pub const YELLOW: &str = "\x1b[33m";
pub const BLUE: &str = "\x1b[34m";
pub const MAGENTA: &str = "\x1b[35m";
pub const CYAN: &str = "\x1b[36m";

/// 256 色扩展常量（rustyline Highlighter 专用）
pub const GRAY: &str = "\x1b[38;5;245m";
pub const HIGHLIGHT_BG: &str = "\x1b[48;5;238m";
pub const HIGHLIGHT_FG: &str = "\x1b[38;5;255m";

/// [*] 蓝色前缀 - 通用信息
#[macro_export]
macro_rules! log_info {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stdout_line(
            &format!("{}{} [*]{} {}", $crate::logger::BOLD, $crate::logger::BLUE, $crate::logger::RESET, msg),
            &format!("[*] {}", msg),
        );
    }};
}

/// [✓] 绿色前缀 - 成功操作
#[macro_export]
macro_rules! log_success {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stdout_line(
            &format!("{}{} [✓]{} {}", $crate::logger::BOLD, $crate::logger::GREEN, $crate::logger::RESET, msg),
            &format!("[✓] {}", msg),
        );
    }};
}

/// [!] 黄色前缀 - 警告
#[macro_export]
macro_rules! log_warn {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stderr_line(
            &format!("{}{} [!]{} {}", $crate::logger::BOLD, $crate::logger::YELLOW, $crate::logger::RESET, msg),
            &format!("[!] {}", msg),
        );
    }};
}

/// [✗] 红色前缀 - 错误（输出到 stderr）
#[macro_export]
macro_rules! log_error {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stderr_line(
            &format!("{}{} [✗]{} {}", $crate::logger::BOLD, $crate::logger::RED, $crate::logger::RESET, msg),
            &format!("[✗] {}", msg),
        );
    }};
}

/// [→] 青色前缀 - 步骤/详细信息
#[macro_export]
macro_rules! log_step {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stdout_line(
            &format!("{}{} [→]{} {}", $crate::logger::BOLD, $crate::logger::CYAN, $crate::logger::RESET, msg),
            &format!("[→] {}", msg),
        );
    }};
}

/// 地址显示 - 带缩进的地址格式化
#[macro_export]
macro_rules! log_addr {
    ($label:expr, $addr:expr) => {{
        let plain = format!("     {}: 0x{:x}", $label, $addr);
        $crate::logger::stdout_line(
            &format!(
                "     {}: {}0x{:x}{}",
                $label,
                $crate::logger::DIM,
                $addr,
                $crate::logger::RESET
            ),
            &plain,
        );
    }};
}

/// [→] 仅 --verbose 时输出的详细步骤信息
#[macro_export]
macro_rules! log_verbose {
    ($($arg:tt)*) => {{
        if $crate::logger::is_verbose() {
            let msg = format!($($arg)*);
            $crate::logger::stdout_line(
                &format!("{}{} [→]{} {}", $crate::logger::BOLD, $crate::logger::CYAN, $crate::logger::RESET, msg),
                &format!("[→] {}", msg),
            );
        }
    }};
}

/// 地址显示 - 仅 --verbose 时输出
#[macro_export]
macro_rules! log_verbose_addr {
    ($label:expr, $addr:expr) => {{
        if $crate::logger::is_verbose() {
            let plain = format!("     {}: 0x{:x}", $label, $addr);
            $crate::logger::stdout_line(
                &format!(
                    "     {}: {}0x{:x}{}",
                    $label,
                    $crate::logger::DIM,
                    $addr,
                    $crate::logger::RESET
                ),
                &plain,
            );
        }
    }};
}

/// [agent] 紫色前缀 - 来自 agent 的消息
#[macro_export]
macro_rules! log_agent {
    ($($arg:tt)*) => {{
        let msg = format!($($arg)*);
        $crate::logger::stdout_line(
            &format!("{}{} [agent]{} {}", $crate::logger::BOLD, $crate::logger::MAGENTA, $crate::logger::RESET, msg),
            &format!("[agent] {}", msg),
        );
    }};
}

/// 打印 banner
pub fn print_banner() {
    let version = env!("CARGO_PKG_VERSION");
    stdout_line(
        &format!(
            "\n {BOLD}{CYAN}╔══════════════════════════════════════╗{RESET}\n \
             {BOLD}{CYAN}║{RESET}  {BOLD}        propctl v{version:<17} {RESET}{BOLD}{CYAN}║{RESET}\n \
             {BOLD}{CYAN}║{RESET}  {DIM}    Android property profile tool  {RESET}{BOLD}{CYAN}║{RESET}\n \
             {BOLD}{CYAN}╚══════════════════════════════════════╝{RESET}\n"
        ),
        &format!(
            "\n ╔══════════════════════════════════════╗\n \
             ║          propctl v{version:<17} ║\n \
             ║    Android property profile tool    ║\n \
             ╚══════════════════════════════════════╝\n"
        ),
    );
}
