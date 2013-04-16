/*
 * Copyright © 2013 Philipp Emanuel Weidmann <pew@worldwidemann.com>
 *
 * Nemo vir est qui mundum non reddat meliorem.
 *
 *
 * This file is part of Final Term.
 *
 * Final Term is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Final Term is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Final Term.  If not, see <http://www.gnu.org/licenses/>.
 */

// TODO: Rename to "TerminalController"?
public class Terminal : Object, Themable {

	private Theme theme;

	public int lines { get; set; }
	public int columns { get; set; }

	public TerminalStream terminal_stream { get; set; default = new TerminalStream(); }
	public TerminalOutput terminal_output { get; set; default = new TerminalOutput(); }
	public TerminalView terminal_view { get; set; }

	private Posix.pid_t fork_pid;
	private int command_file;
	private IOChannel command_channel;

	public Terminal() {
		lines = FinalTerm.settings.terminal_lines;
		columns = FinalTerm.settings.terminal_columns;

		terminal_stream.element_added.connect(on_stream_element_added);
		terminal_stream.transient_text_updated.connect(on_stream_transient_text_updated);
		terminal_output.text_updated.connect(on_output_text_updated);
		terminal_output.command_updated.connect(on_output_command_updated);
		terminal_output.command_executed.connect(on_output_command_executed);
		terminal_output.title_updated.connect(on_output_title_updated);
		terminal_output.progress_updated.connect(on_output_progress_updated);
		terminal_output.progress_finished.connect(on_output_progress_finished);
		terminal_output.cursor_position_changed.connect(on_output_cursor_position_changed);

		initialize_pty();

		FinalTerm.register_themable(this);
	}

	public bool is_autocompletion_active() {
		return terminal_output.command_mode && FinalTerm.autocompletion.is_popup_visible();
	}

	public void update_autocompletion_position() {
		int x;
		int y;
		terminal_view.terminal_output_view.get_screen_position(
				terminal_output.command_start_position, out x, out y);
		// Move popup one character down so it doesn't occlude the input
		y += theme.character_height;
		FinalTerm.autocompletion.move_popup(x, y);
	}

	public void clear_command() {
		// TODO: Handle cases where cursor is not at the end of the line
		for (int i = 0; i < terminal_output.get_command().char_count(); i++) {
			send_character(0x7F);
		}
	}

	public void set_command(string command) {
		clear_command();
		send_text(command);
	}

	public void run_command(string command) {
		set_command(command);
		send_text("\n");
	}

	private void on_stream_element_added(TerminalStream.StreamElement stream_element) {
		terminal_output.parse_stream_element(stream_element);
	}

	private void on_stream_transient_text_updated(string transient_text) {
		terminal_output.parse_transient_text(transient_text);
	}

	private void on_output_text_updated(int line_index) {
		terminal_view.terminal_output_view.mark_line_as_updated(line_index);

		// TODO: Add information about instance to key
		Utilities.schedule_execution(terminal_view.terminal_output_view.render_terminal_output,
				"render_terminal_output", FinalTerm.settings.render_interval);
	}

	private void on_output_command_updated(string command) {
		message("Command updated: '%s'", command);

		// TODO: This should be scheduled to avoid congestion
		FinalTerm.autocompletion.show_popup(command);
		update_autocompletion_position();
	}

	private void on_output_command_executed(string command) {
		message("Command executed: '%s'", command);
		FinalTerm.autocompletion.hide_popup();
		FinalTerm.autocompletion.add_command(command.strip());
	}

	private void on_output_title_updated(string new_title) {
		title_updated(new_title);
	}

	private void on_output_progress_updated(int percentage) {
		terminal_view.show_progress("Progress", percentage);
	}

	private void on_output_progress_finished() {
		terminal_view.hide_progress();
	}

	private void on_output_cursor_position_changed(TerminalOutput.CursorPosition new_position) {
		// TODO: This does not currently work because the line has yet to be rendered
		//terminal_view.scroll_to_position(new_position.line, new_position.column);

		// TODO: Add information about instance to key
		Utilities.schedule_execution(terminal_view.terminal_output_view.render_terminal_output,
				"render_terminal_output", FinalTerm.settings.render_interval);
	}

	public void send_character(unichar character) {
		command_channel.write_unichar(character);
		command_channel.flush();
	}

	public void send_text(string text) {
		var text_chars = text.to_utf8();
		size_t bytes_written;
		command_channel.write_chars(text_chars, out bytes_written);
		command_channel.flush();
	}

	// Makes the PTY aware that the size (lines and columns)
	// of the terminal has been changed
	public void update_size() {
		Linux.winsize terminal_size = { (ushort)lines, (ushort)columns, 0, 0 };
		Linux.ioctl(command_file, Linux.Termios.TIOCSWINSZ, terminal_size);
	}

	private void initialize_pty() {
		int pty_master;
		char[] slave_name = null;
		Linux.winsize terminal_size = { (ushort)lines, (ushort)columns, 0, 0 };

		fork_pid = Linux.forkpty(out pty_master, slave_name, null, terminal_size);

		switch (fork_pid) {
		case -1: // Error
			critical("Fork failed");
			break;
		case 0: // This is the child process
			run_shell();
			break;
		default: // This is the parent process
			command_file = pty_master;
			initialize_read();
			break;
		}
	}

	private void run_shell() {
		Environment.set_variable("TERM", FinalTerm.settings.emulated_terminal, true);

		// Replace child process with shell process
		Posix.execvp(FinalTerm.settings.shell_path,
				{ FinalTerm.settings.shell_path, "--rcfile", "Startup/bash_startup", "-i" });

		// If this line is reached, execvp() must have failed
		critical("execvp failed");
		Posix.exit(Posix.EXIT_FAILURE);
	}

	private void initialize_read() {
		command_channel = new IOChannel.unix_new(command_file);

		command_channel.add_watch(IOCondition.IN, (source, condition) => {
			if (condition == IOCondition.HUP) {
				message("Connection broken");
				return false;
			}

			// TODO: Read all available characters rather than one
			unichar character;
			command_channel.read_unichar(out character);

			// Measured from outside because parse_character has multiple return points
			//Metrics.start_block_timer("TerminalStream.parse_character (outside)");
			terminal_stream.parse_character(character);
			//Metrics.stop_block_timer("TerminalStream.parse_character (outside)");

			return true;
		});
	}

	public void set_theme(Theme theme) {
		this.theme = theme;

		if (is_autocompletion_active())
			update_autocompletion_position();
	}

	// TODO: Rename to "title_changed"?
	public signal void title_updated(string new_title);

}
