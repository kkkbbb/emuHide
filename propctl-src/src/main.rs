#![cfg(all(target_os = "android", target_arch = "aarch64"))]

mod logger;
mod props;

fn usage() -> ! {
    eprintln!(
        "usage:
  propctl dump-props <profile>
  propctl set-prop <profile> <key=value>
  propctl del-prop <profile> <key>
  propctl repack-props <profile>"
    );
    std::process::exit(2);
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().unwrap_or_else(|| usage());

    match cmd.as_str() {
        "dump-props" => {
            let profile = args.next().unwrap_or_else(|| usage());
            if args.next().is_some() {
                usage();
            }
            props::dump_props(&profile)
        }
        "set-prop" => {
            let profile = args.next().unwrap_or_else(|| usage());
            let key_value = args.next().unwrap_or_else(|| usage());
            if args.next().is_some() {
                usage();
            }
            props::set_prop(&profile, &key_value)
        }
        "del-prop" => {
            let profile = args.next().unwrap_or_else(|| usage());
            let key = args.next().unwrap_or_else(|| usage());
            if args.next().is_some() {
                usage();
            }
            props::del_prop(&profile, &key)
        }
        "repack-props" => {
            let profile = args.next().unwrap_or_else(|| usage());
            if args.next().is_some() {
                usage();
            }
            props::repack_props(&profile)
        }
        _ => usage(),
    }
}

fn main() {
    if let Err(e) = run() {
        log_error!("{}", e);
        std::process::exit(1);
    }
}
