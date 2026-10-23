//! iOS stand-in for the part of `craft-print` that Print uses. iOS has no CUPS or Windows
//! spooler, so there is no system backend and every job goes to the app's spooler.
#![allow(dead_code)]

#[derive(Debug)]
pub struct Error(&'static str);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

pub struct Printer {
    pub name: String,
    pub default: bool,
}

#[derive(Default)]
pub enum Scaling {
    #[default]
    Exact,
}

#[derive(Default)]
pub struct Job {
    pub printer: Option<String>,
    pub copies: u32,
    pub title: String,
    pub scaling: Scaling,
}

pub enum Backend {
    Cups,
    WindowsPdf,
}

pub fn backend() -> Option<Backend> {
    None
}

pub fn printers() -> Vec<Printer> {
    Vec::new()
}

pub fn submit(_: &[u8], _: &Job) -> Result<String, Error> {
    Err(Error("there is no system print spooler on iOS"))
}

/// No command is started on iOS.
pub fn command_preview(_: &Job) -> Result<Vec<String>, Error> {
    Ok(Vec::new())
}
