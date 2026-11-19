// SQLite, in the shape goose-sqlite gives the Goose program: a database, a
// prepared statement, parameters from 1, columns from 0, text as bytes.
// A thin layer over the C API (libsqlite3-sys), so every script and every
// statement of the Goose program runs here as it is.

use crate::util::die;
use libsqlite3_sys as ffi;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

pub struct Db(*mut ffi::sqlite3);
pub struct Stmt(*mut ffi::sqlite3_stmt, *mut ffi::sqlite3);

unsafe fn errmsg(db: *mut ffi::sqlite3) -> String {
    if db.is_null() { return "out of memory".to_string(); }
    CStr::from_ptr(ffi::sqlite3_errmsg(db)).to_string_lossy().into_owned()
}

impl Db {
    fn open_flags(path: &[u8], flags: c_int) -> Result<Db, String> {
        let c = CString::new(path).map_err(|_| "a path cannot hold a NUL".to_string())?;
        let mut db: *mut ffi::sqlite3 = ptr::null_mut();
        unsafe {
            if ffi::sqlite3_open_v2(c.as_ptr(), &mut db, flags, ptr::null()) != ffi::SQLITE_OK {
                let e = errmsg(db);
                ffi::sqlite3_close(db);
                return Err(e);
            }
        }
        Ok(Db(db))
    }
    /// Creates the file if needed.
    pub fn open(path: &[u8]) -> Result<Db, String> {
        Db::open_flags(path, ffi::SQLITE_OPEN_READWRITE | ffi::SQLITE_OPEN_CREATE)
    }
    /// Read and write; never creates a missing file.
    pub fn open_existing(path: &[u8]) -> Result<Db, String> {
        Db::open_flags(path, ffi::SQLITE_OPEN_READWRITE)
    }
    /// One or more statements.
    pub fn exec(&self, sql: &[u8]) -> Result<(), String> {
        let c = CString::new(sql).map_err(|_| "a script cannot hold a NUL".to_string())?;
        unsafe {
            if ffi::sqlite3_exec(self.0, c.as_ptr(), None, ptr::null_mut(), ptr::null_mut()) != ffi::SQLITE_OK {
                return Err(errmsg(self.0));
            }
        }
        Ok(())
    }
    pub fn exec_or_die(&self, sql: &[u8]) {
        if let Err(e) = self.exec(sql) { die(&format!("sqlite: {} in: {}", e, String::from_utf8_lossy(sql))); }
    }
    pub fn prepare(&self, sql: &[u8]) -> Result<Stmt, String> {
        let mut st: *mut ffi::sqlite3_stmt = ptr::null_mut();
        unsafe {
            if ffi::sqlite3_prepare_v2(self.0, sql.as_ptr() as *const c_char, sql.len() as c_int, &mut st, ptr::null_mut()) != ffi::SQLITE_OK
                || st.is_null()
            {
                return Err(errmsg(self.0));
            }
        }
        Ok(Stmt(st, self.0))
    }
    pub fn prepare_or_die(&self, sql: &[u8]) -> Stmt {
        match self.prepare(sql) {
            Ok(s) => s,
            Err(e) => die(&format!("sqlite: {} in: {}", e, String::from_utf8_lossy(sql))),
        }
    }
    pub fn last_rowid(&self) -> i64 { unsafe { ffi::sqlite3_last_insert_rowid(self.0) } }
    /// One integer from a query with no parameters (0 when it gives no row).
    pub fn scalar(&self, sql: &[u8]) -> i64 {
        let st = self.prepare_or_die(sql);
        if st.step_row() { st.col_int(0) } else { 0 }
    }
}

impl Drop for Db {
    fn drop(&mut self) { unsafe { ffi::sqlite3_close(self.0); } }
}

impl Stmt {
    pub fn bind_text(&self, i: i32, v: &[u8]) {
        unsafe { ffi::sqlite3_bind_text(self.0, i, v.as_ptr() as *const c_char, v.len() as c_int, ffi::SQLITE_TRANSIENT()); }
    }
    pub fn bind_int(&self, i: i32, v: i64) {
        unsafe { ffi::sqlite3_bind_int64(self.0, i, v); }
    }
    /// 1 a row, 0 done, -1 an error (its text in err).
    pub fn step(&self, err: &mut String) -> i32 {
        unsafe {
            match ffi::sqlite3_step(self.0) {
                ffi::SQLITE_ROW => 1,
                ffi::SQLITE_DONE => 0,
                _ => { *err = errmsg(self.1); -1 }
            }
        }
    }
    /// A row or not; an error ends the run.
    pub fn step_row(&self) -> bool {
        let mut e = String::new();
        match self.step(&mut e) {
            1 => true,
            0 => false,
            _ => die(&format!("sqlite: {}", e)),
        }
    }
    /// Runs to the end, then resets (and clears the parameters).
    pub fn step_done(&self) {
        while self.step_row() {}
        self.reset();
    }
    pub fn col_int(&self, i: i32) -> i64 { unsafe { ffi::sqlite3_column_int64(self.0, i) } }
    pub fn col_text(&self, i: i32) -> Vec<u8> {
        unsafe {
            let p = ffi::sqlite3_column_text(self.0, i);
            if p.is_null() { return Vec::new(); }
            let n = ffi::sqlite3_column_bytes(self.0, i) as usize;
            std::slice::from_raw_parts(p, n).to_vec()
        }
    }
    /// Ready to run again, with no parameters set.
    pub fn reset(&self) {
        unsafe {
            ffi::sqlite3_reset(self.0);
            ffi::sqlite3_clear_bindings(self.0);
        }
    }
}

impl Drop for Stmt {
    fn drop(&mut self) { unsafe { ffi::sqlite3_finalize(self.0); } }
}
