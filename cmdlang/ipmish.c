/*
 * ipmish.c
 *
 * MontaVista IPMI basic UI to use the main UI code.
 *
 * Author: MontaVista Software, Inc.
 *         Corey Minyard <minyard@mvista.com>
 *         source@mvista.com
 *
 * Copyright 2002,2003 MontaVista Software Inc.
 *
 *  This program is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public License
 *  as published by the Free Software Foundation; either version 2 of
 *  the License, or (at your option) any later version.
 *
 *
 *  THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
 *  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 *  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 *  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
 *  OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 *  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 *  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
 *  USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this program; if not, write to the Free
 *  Software Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>
#include <OpenIPMI/selector.h>
#include <OpenIPMI/ipmi_conn.h>
#include <OpenIPMI/ipmi_posix.h>
#include <OpenIPMI/ipmi_cmdlang.h>
#include <OpenIPMI/ipmi_debug.h>

/* Internal includes, do not use in your programs */
#include <OpenIPMI/internal/ipmi_malloc.h>

#ifdef HAVE_UCDSNMP
# ifdef HAVE_NETSNMP
#  include <net-snmp/net-snmp-config.h>
#  include <net-snmp/net-snmp-includes.h>
# elif defined(HAVE_ALT_UCDSNMP_DIR)
#  include <ucd-snmp/asn1.h>
#  include <ucd-snmp/snmp_api.h>
#  include <ucd-snmp/snmp.h>
# else
#  include <asn1.h>
#  include <snmp_api.h>
#  include <snmp.h>
# endif
#endif

selector_t *debug_sel;
extern os_handler_t ipmi_debug_os_handlers;

static int done = 0;
static int evcount = 0;
static int handling_input = 0;
static char *line_buffer;
static int  line_buffer_max = 0;
static int  line_buffer_pos = 0;

static void
redraw_cmdline(void)
{
    if (!done && handling_input) {
	fputs("> ", stdout);
	fwrite(line_buffer, 1, line_buffer_pos, stdout);
	fflush(stdout);
    }
}

void
posix_vlog(char *format,
	   enum ipmi_log_type_e log_type,
	   va_list ap)
{
    int do_nl = 1;
    static int last_was_cont = 0;

    if (handling_input && !last_was_cont && !done) 
	fputc('\n', stdout);

    last_was_cont = 0;
    switch(log_type) {
    case IPMI_LOG_INFO:
	printf("INFO: ");
	break;

    case IPMI_LOG_WARNING:
	printf("WARN: ");
	break;

    case IPMI_LOG_SEVERE:
	printf("SEVR: ");
	break;

    case IPMI_LOG_FATAL:
	printf("FATL: ");
	break;

    case IPMI_LOG_ERR_INFO:
	printf("EINF: ");
	break;

    case IPMI_LOG_DEBUG_START:
	do_nl = 0;
	last_was_cont = 1;
	/* FALLTHROUGH */
    case IPMI_LOG_DEBUG:
	printf("DEBG: ");
	break;

    case IPMI_LOG_DEBUG_CONT:
	last_was_cont = 1;
	do_nl = 0;
	/* FALLTHROUGH */
    case IPMI_LOG_DEBUG_END:
	break;
    }

    vprintf(format, ap);
    if (do_nl) {
	printf("\n");
	redraw_cmdline();
    }
}
void
debug_vlog(char *format,
	   enum ipmi_log_type_e log_type,
	   va_list ap)
{
    posix_vlog(format, log_type, ap);
}

#ifdef HAVE_UCDSNMP
#define IPMI_OID_SIZE 9
static oid ipmi_oid[IPMI_OID_SIZE] = {1,3,6,1,4,1,3183,1,1};
int snmp_input(int op,
	       struct snmp_session *session,
	       int reqid,
	       struct snmp_pdu *pdu,
	       void *magic)
{
    struct sockaddr_in   *src_ip;
    uint32_t             specific;
    struct variable_list *var;

#ifdef HAVE_NETSNMP
    if (op != NETSNMP_CALLBACK_OP_RECEIVED_MESSAGE)
	goto out;
#else
    if (op != RECEIVED_MESSAGE)
	goto out;
#endif
    if (pdu->command != SNMP_MSG_TRAP)
	goto out;
    if (snmp_oid_compare(ipmi_oid, IPMI_OID_SIZE,
			 pdu->enterprise, pdu->enterprise_length)
	!= 0)
    {
	goto out;
    }
    if (pdu->trap_type != SNMP_TRAP_ENTERPRISESPECIFIC)
	goto out;

    src_ip = (struct sockaddr_in *) &pdu->agent_addr;
    specific = pdu->specific_type;

    var = pdu->variables;
    if (var == NULL)
	goto out;
    if (var->type != ASN_OCTET_STR)
	goto out;
    if (snmp_oid_compare(ipmi_oid, IPMI_OID_SIZE, var->name, var->name_length)
	!= 0)
    {
	goto out;
    }
    if (var->val_len < 46)
	goto out;
    
    ipmi_handle_snmp_trap_data(src_ip,
		    	       sizeof(*src_ip),
			       IPMI_EXTERN_ADDR_IP,
			       specific,
			       var->val.string,
			       var->val_len);

 out:
    return 1;
}

#ifdef HAVE_NETSNMP
static int
snmp_pre_parse(netsnmp_session * session, netsnmp_transport *transport,
	       void *transport_data, int transport_data_length)
{
    return 1;
}
#else
static int
snmp_pre_parse(struct snmp_session *session, snmp_ipaddr from)
{
    return 1;
}
#endif

static struct snmp_session *snmp_session;

static void
snmp_add_read_fds(selector_t     *sel,
		  int            *num_fds,
		  fd_set         *fdset,
		  struct timeval *timeout,
		  int            *timeout_invalid,
		  void           *cb_data)
{
    snmp_select_info(num_fds, fdset, timeout, timeout_invalid);
}

static void
snmp_check_read_fds(selector_t *sel,
		    fd_set     *fds,
		    void       *cb_data)
{
    snmp_read(fds);
}

static void
snmp_check_timeout(selector_t *sel,
		   void       *cb_data)
{
    snmp_timeout();
}

static int
snmp_init(selector_t *sel)
{
    struct snmp_session session;
#ifdef HAVE_NETSNMP
    netsnmp_transport *transport = NULL;
    static char *snmp_default_port = "udp:162";

    netsnmp_ds_set_boolean(NETSNMP_DS_LIBRARY_ID,
			   NETSNMP_DS_LIB_MIB_ERRORS,
			   0);

    init_snmp("ipmish");

    transport = netsnmp_tdomain_transport(snmp_default_port, 1, "udp");
    if (!transport) {
        snmp_sess_perror("ipmish", &session);
	return -1;
    }
#else
    void *transport = NULL;
#endif
    snmp_sess_init(&session);
    session.peername = SNMP_DEFAULT_PEERNAME;
    session.version = SNMP_DEFAULT_VERSION;
    session.community_len = SNMP_DEFAULT_COMMUNITY_LEN;
    session.retries = SNMP_DEFAULT_RETRIES;
    session.timeout = SNMP_DEFAULT_TIMEOUT;
    session.local_port = SNMP_TRAP_PORT;
    session.callback = snmp_input;
    session.callback_magic = transport;
    session.authenticator = NULL;
    session.isAuthoritative = SNMP_SESS_UNKNOWNAUTH;

#ifdef HAVE_NETSNMP
    snmp_session = snmp_add(&session, transport, snmp_pre_parse, NULL);
#else
    snmp_session = snmp_open_ex(&session, snmp_pre_parse,
				NULL, NULL, NULL, NULL);
#endif
    if (snmp_session == NULL) {
        snmp_sess_perror("ipmish", &session);
	return -1;
    }

    ipmi_sel_set_read_fds_handler(sel,
				  snmp_add_read_fds,
				  snmp_check_read_fds,
				  snmp_check_timeout,
				  NULL);

    return 0;
}
#endif /* HAVE_UCDSNMP */

typedef struct out_data_s
{
    FILE *stream;
    int  indent;
} out_data_t;

static int columns = 80;

static void
out_help(FILE *s, int indent, char *name, char *v)
{
    int pos, endpos;
    char *endword;
    char *endspace;

    pos = fprintf(s, "%*s%s ", indent, "", name);
    while (*v) {
	endword = v;
	while (isspace(*endword)) {
	    if (*endword == '\n') {
		v = endword + 1;
		fprintf(s, "\n%*s", indent+2, "");
		pos = indent + 2;
	    }
	    endword++;
	}
	endspace = endword;
	while (*endword && !isspace(*endword))
	    endword++;
	endpos = pos + endword - v;
	if (endpos > columns) {
	    v = endspace;
	    fprintf(s, "\n%*s", indent+2, "");
	    pos = indent + 2;
	}
	fwrite(v, 1, endword-v, s);
	pos += endword - v;
	v = endword;
    }
    fputc('\n', s);
}

static void
out_value(ipmi_cmdlang_t *info, char *name, char *value)
{
    out_data_t *out_data = info->user_data;

    if (value) {
	if (info->help) {
	    out_help(out_data->stream, out_data->indent*2, name, value);
	} else {
	    fprintf(out_data->stream, "%*s%s: %s\n", out_data->indent*2, "",
		    name, value);
	}
    } else
	fprintf(out_data->stream, "%*s%s\n", out_data->indent*2, "", name);
    fflush(out_data->stream);
}

static void
out_binary(ipmi_cmdlang_t *info, char *name, char *value, unsigned int len)
{
    out_data_t *out_data = info->user_data;
    unsigned char *data = (unsigned char *) value;
    int indent2 = (out_data->indent * 2) + strlen(name) + 1;
    int i;
    char *sep = ":";

    if (info->help)
      sep = "";

    fprintf(out_data->stream, "%*s%s%s", out_data->indent*2, "", name, sep);
    for (i=0; i<len; i++) {
	if ((i != 0) && ((i % 8) == 0))
	    fprintf(out_data->stream, "\n%*s", indent2, "");
	fprintf(out_data->stream, " 0x%2.2x", (data[i] & 0xff));
    }
    fprintf(out_data->stream, "\n");
    
    fflush(out_data->stream);
}

static void
out_unicode(ipmi_cmdlang_t *info, char *name, char *value, unsigned int len)
{
    out_data_t *out_data = info->user_data;
    char *sep = ":";

    if (info->help)
      sep = "";

    fprintf(out_data->stream, "%*s%s%s %s\n", out_data->indent*2, "",
	    name, sep, "Unicode!");
    fflush(out_data->stream);
}

static void
down_level(ipmi_cmdlang_t *info)
{
    out_data_t *out_data = info->user_data;

    out_data->indent++;
}

static void
up_level(ipmi_cmdlang_t *info)
{
    out_data_t *out_data = info->user_data;

    out_data->indent--;
}

static void cmd_done(ipmi_cmdlang_t *info);

static out_data_t lout_data =
{
    .stream = NULL,
    .indent = 0,
};
static char cmdlang_objstr[IPMI_MAX_NAME_LEN];
static ipmi_cmdlang_t cmdlang =
{
    .out = out_value,
    .out_binary = out_binary,
    .out_unicode = out_unicode,
    .down = down_level,
    .up = up_level,
    .done = cmd_done,

    .os_hnd = NULL,
    .selector = NULL,

    .user_data = &lout_data,

    .objstr = cmdlang_objstr,
    .objstr_len = sizeof(cmdlang_objstr),
};

int *done_ptr = NULL;

static void
cmd_done(ipmi_cmdlang_t *info)
{
    out_data_t *out_data = info->user_data;

    if (info->err) {
	if (!info->location)
	    info->location = "";
	if (strlen(info->objstr) == 0) {
	    fprintf(out_data->stream, "error: %s: %s (0x%x)\n",
		    info->location, info->errstr,
		    info->err);
	} else {
	    fprintf(out_data->stream, "error: %s %s: %s (0x%x)\n",
		    info->location, info->objstr, info->errstr,
		    info->err);
	}
	if (info->errstr_dynalloc)
	    ipmi_mem_free(info->errstr);
	info->errstr_dynalloc = 0;
	info->errstr = NULL;
	info->location = NULL;
	info->objstr[0] = '\0';
	info->err = 0;
    }

    if (done_ptr) {
	*done_ptr = 1;
    } else {
	handling_input = 1;
	redraw_cmdline();
	sel_set_fd_read_handler(info->selector, 0, SEL_FD_HANDLER_ENABLED);
	out_data->indent = 0;
	fflush(out_data->stream);
    }
}

void
ipmi_cmdlang_global_err(char *objstr,
			char *location,
			char *errstr,
			int  errval)
{
    if (handling_input && !done)
	fputc('\n', stdout);
    if (objstr)
	fprintf(stderr, "global error: %s %s: %s (0x%x)", location, objstr,
		errstr, errval);
    else
	fprintf(stderr, "global error: %s: %s (0x%x)", location,
		errstr, errval);
    evcount = 0;
    redraw_cmdline();
}

void
ipmi_cmdlang_report_event(ipmi_cmdlang_event_t *event)
{
    unsigned int                level, len;
    enum ipmi_cmdlang_out_types type;
    char                        *name, *value;
    int                         indent2;
    int                         i;

    if (handling_input && !done)
	fputc('\n', stdout);
    ipmi_cmdlang_event_restart(event);
    printf("Event\n");
    while (ipmi_cmdlang_event_next_field(event, &level, &type, &name, &len,
					 &value))
    {
	switch (type) {
	case IPMI_CMDLANG_STRING:
	    if (value)
		printf("  %*s%s: %s\n", level*2, "", name, value);
	    else
		printf("  %*s%s\n", level*2, "", name);
	    break;

	case IPMI_CMDLANG_BINARY:
	case IPMI_CMDLANG_UNICODE:
	    indent2 = (level * 2) + strlen(name) + 1;
	    printf("  %*s%s:", level*2, "", name);
	    for (i=0; i<len; i++) {
		if ((i != 0) && ((i % 8) == 0))
		    printf("\n  %*s", indent2, "");
		printf(" 0x%2.2x", value[i] & 0xff);
	    }
	    printf("\n");
    
	    fflush(stdout);
	    break;
	}
    }
    evcount = 0;
    redraw_cmdline();
}

static void
user_input_ready(int fd, void *data)
{
    ipmi_cmdlang_t *info = data;
    out_data_t *out_data = info->user_data;
    char rc;
    int  count;
    int  i;

    count = read(fd, &rc, 1);
    if (count <= 0) {
	done = 1;
	evcount = 1; /* Force a newline */
	return;
    }

    switch(rc) {
    case 0x04: /* ^d */
	if (line_buffer_pos == 0) {
	    done = 1;
	    evcount = 1; /* Force a newline */
	}
	break;

    case 12: /* ^l */
	fputc('\n', out_data->stream);
	redraw_cmdline();
	break;

    case '\r': case '\n':
	fputc(rc, out_data->stream);
	if (line_buffer) {
	    line_buffer[line_buffer_pos] = '\0';
	    for (i=0; isspace(line_buffer[i]); i++)
		;
	    /* Ignore blank lines. */
	    if (line_buffer[i] != '\0') {
		/* Turn off input processing. */
		sel_set_fd_read_handler(info->selector, 0,
					SEL_FD_HANDLER_DISABLED);

		cmdlang.err = 0;
		cmdlang.errstr = NULL;
		cmdlang.errstr_dynalloc = 0;
		cmdlang.location = NULL;
		handling_input = 0;
		line_buffer_pos = 0;
		ipmi_cmdlang_handle(&cmdlang, line_buffer);
	    } else {
		fputs("> ", out_data->stream);
	    }
	} else {
	    fputs("> ", out_data->stream);
	}
	break;

    case 0x7f: /* delete */
    case '\b': /* backspace */
	if (line_buffer_pos > 0) {
	    line_buffer_pos--;
	    fputs("\b \b", out_data->stream);
	}
	break;

    default:
	if (line_buffer_pos >= line_buffer_max) {
	    char *new_line = ipmi_mem_alloc(line_buffer_max+10+1);
	    if (!new_line)
		break;
	    line_buffer_max += 10;
	    if (line_buffer) {
		memcpy(new_line, line_buffer, line_buffer_pos);
		ipmi_mem_free(line_buffer);
	    }
	    line_buffer = new_line;
	}
	line_buffer[line_buffer_pos] = rc;
	line_buffer_pos++;
	fputc(rc, out_data->stream);
	break;
    }

    fflush(out_data->stream);
}

static int term_setup;
struct termios old_termios;

static void
cleanup_term(os_handler_t *os_hnd, selector_t *sel)
{
    if (line_buffer) {
	ipmi_mem_free(line_buffer);
	line_buffer = NULL;
    }
    sel_clear_fd_handlers(sel, 0);

    if (!term_setup)
	return;

    tcsetattr(0, TCSADRAIN, &old_termios);
    tcdrain(0);
    term_setup = 0;
}

static void cleanup_sig(int sig);

static void
setup_term(os_handler_t *os_hnd, selector_t *sel)
{
    struct termios new_termios;

    tcgetattr(0, &old_termios);
    new_termios = old_termios;
    new_termios.c_lflag &= ~(ICANON|ECHO);
    tcsetattr(0, TCSADRAIN, &new_termios);
    term_setup = 1;

    signal(SIGINT, cleanup_sig);
    signal(SIGPIPE, cleanup_sig);
    signal(SIGUSR1, cleanup_sig);
    signal(SIGUSR2, cleanup_sig);
    signal(SIGPWR, cleanup_sig);

    lout_data.stream = stdout;

    cmdlang.os_hnd = os_hnd;
    cmdlang.selector = sel;

    sel_set_fd_handlers(sel, 0, &cmdlang, user_input_ready, NULL, NULL, NULL);
    sel_set_fd_read_handler(sel, 0, SEL_FD_HANDLER_DISABLED);
}

static void
exit_cmd(ipmi_cmd_info_t *cmd_info)
{
    done = 1;
    evcount = 0;
    ipmi_cmdlang_out(cmd_info, "Exiting ipmish", NULL);
}

static int read_nest = 0;
static void
read_cmd(ipmi_cmd_info_t *cmd_info)
{
    ipmi_cmdlang_t *cmdlang = ipmi_cmdinfo_get_cmdlang(cmd_info);
    int            cdone;
    char           cmdline[256];
    FILE           *s;
    out_data_t     my_out_data;
    ipmi_cmdlang_t my_cmdlang = *cmdlang;
    int            curr_arg = ipmi_cmdlang_get_curr_arg(cmd_info);
    int            argc = ipmi_cmdlang_get_argc(cmd_info);
    char           **argv = ipmi_cmdlang_get_argv(cmd_info);
    int            *saved_done_ptr;
    char           *fname;

    if ((argc - curr_arg) < 1) {
	cmdlang->errstr = "No filename entered";
	cmdlang->err = EINVAL;
	goto out_err;
    }

    fname = argv[curr_arg];
    curr_arg++;
    s = fopen(fname, "r");
    if (!s) {
	cmdlang->errstr = "Unable to openfile";
	cmdlang->err = errno;
	goto out_err;
    }

    if (!read_nest) {
	handling_input = 0;
	sel_set_fd_read_handler(cmdlang->selector, 0, SEL_FD_HANDLER_DISABLED);
    }
    read_nest++;
    saved_done_ptr = done_ptr;

    while (fgets(cmdline, sizeof(cmdline), s)) {
	my_out_data.stream = stdout;
	my_out_data.indent = 0;
	my_cmdlang.user_data = &my_out_data;
	cdone = 0;
	done_ptr = &cdone;
	printf("> %s", cmdline);
	ipmi_cmdlang_handle(&my_cmdlang, cmdline);
	while (!cdone)
	    cmdlang->os_hnd->perform_one_op(cmdlang->os_hnd, NULL);
	done_ptr = NULL;
    }
    fclose(s);

    done_ptr = saved_done_ptr
;
    read_nest--;
    if (!read_nest) {
	handling_input = 1;
	sel_set_fd_read_handler(cmdlang->selector, 0, SEL_FD_HANDLER_ENABLED);
    }

    ipmi_cmdlang_out(cmd_info, "File read", fname);

    return;

 out_err:
    cmdlang->location = "ipmish.c(read_cmd)";
}

static void
setup_cmds(void)
{
    int rv;

    rv = ipmi_cmdlang_reg_cmd(NULL,
			      "exit",
			      "- leave the program",
			      exit_cmd, NULL, NULL);
    if (rv) {
	fprintf(stderr, "Error adding exit command: 0x%x\n", rv);
	exit(1);
    }

    rv = ipmi_cmdlang_reg_cmd(NULL,
			      "read",
			      "<file> - Read commands from the file and"
			      " execute them",
			      read_cmd, NULL, NULL);
    if (rv) {
	fprintf(stderr, "Error adding read command: 0x%x\n", rv);
	exit(1);
    }
}

static void
domain_down(void *cb_data)
{
    int *count = cb_data;
    (*count)--;
}

static void
shutdown_domain_handler(ipmi_domain_t *domain, void *cb_data)
{
    int *count = cb_data;
    int rv;

    rv = ipmi_domain_close(domain, domain_down, cb_data);
    if (!rv)
	(*count)++;
}

static void
cleanup_sig(int sig)
{
    fprintf(stderr, "Exiting due to signal %d\n", sig);
    done = 0;
    ipmi_domain_iterate_domains(shutdown_domain_handler, &done);
    while (done)
	cmdlang.os_hnd->perform_one_op(cmdlang.os_hnd, NULL);
    cleanup_term(cmdlang.os_hnd, cmdlang.selector);
    exit(1);
}

typedef struct exec_list_s
{
    char *str;
    struct exec_list_s *next;
} exec_list_t;
static exec_list_t *execs, *execs_tail;

static void
add_exec_str(char *str)
{
    exec_list_t *e;

    e = malloc(sizeof(*e));
    if (!e) {
	fprintf(stderr, "Out of memory");
	exit(1);
    }
    e->str = str;
    e->next = NULL;
    if (execs)
	execs_tail->next = e;
    else {
	execs = e;
	execs_tail = e;
    }
}

static char *usage_str =
"%s is a program that gives access to the OpenIPMI library from a command\n"
"line.  It is designed to be script driven.  Format is:\n"
"  %s [options]\n"
"Options are:\n"
"  --execute <string> - execute the given string at startup.  This may be\n"
"    entered multiple times for multiple commands.\n"
"  -x <string> - same as --execute\n"
"  --dlock - turn on lock debugging.\n"
"  --dmem - turn on memory debugging.\n"
"  --drawmsg - turn on raw message tracing.\n"
"  --dmsg - turn on message tracing debugging.\n"
"  --dmsgerr - turn on printing out low-level message errors.\n"
#ifdef HAVE_UCDSNMP
"  --snmp - turn on SNMP trap handling.\n"
#endif
"  --help - This output.\n"
;
static void usage(char *name)
{
    fprintf(stderr, usage_str, name, name);
}

int
main(int argc, char *argv[])
{
    int              rv;
    int              curr_arg = 1;
    const char       *arg;
#ifdef HAVE_UCDSNMP
    int              init_snmp = 0;
#endif
    os_handler_t     *os_hnd;
    selector_t       *sel;
    int              use_debug_os = 0;
    char             *colstr;

    colstr = getenv("COLUMNS");
    if (colstr) {
	int tmp = strtoul(colstr, NULL, 0);
	if (tmp) 
	    columns = tmp;
    }

    while ((curr_arg < argc) && (argv[curr_arg][0] == '-')) {
	arg = argv[curr_arg];
	curr_arg++;
	if (strcmp(arg, "--") == 0) {
	    break;
	} else if ((strcmp(arg, "-x") == 0) || (strcmp(arg, "--execute") == 0))
	{
	    if (curr_arg >= argc) {
		fprintf(stderr, "No option given for %s", arg);
		usage(argv[0]);
		return 1;
	    }
	    add_exec_str(argv[curr_arg]);
	    curr_arg++;
	} else if (strcmp(arg, "--dlock") == 0) {
	    DEBUG_LOCKS_ENABLE();
	    use_debug_os = 1;
	} else if (strcmp(arg, "--dmem") == 0) {
	    DEBUG_MALLOC_ENABLE();
	} else if (strcmp(arg, "--drawmsg") == 0) {
	    DEBUG_RAWMSG_ENABLE();
	} else if (strcmp(arg, "--dmsg") == 0) {
	    DEBUG_MSG_ENABLE();
	} else if (strcmp(arg, "--dmsgerr") == 0) {
	    DEBUG_MSG_ERR_ENABLE();
#ifdef HAVE_UCDSNMP
	} else if (strcmp(arg, "--snmp") == 0) {
	    init_snmp = 1;
#endif
	} else if (strcmp(arg, "--help") == 0) {
	    usage(argv[0]);
	    return 0;
	} else {
	    fprintf(stderr, "Unknown option: %s\n", arg);
	    usage(argv[0]);
	    return 1;
	}
    }

    if (use_debug_os) {
	os_hnd = &ipmi_debug_os_handlers;
	rv = sel_alloc_selector(os_hnd, &sel);
	if (rv) {
	    fprintf(stderr, "Could not allocate selector\n");
	    return 1;
	}
	debug_sel = sel;
    } else {
	os_hnd = ipmi_posix_setup_os_handler();
	if (!os_hnd) {
	    fprintf(stderr,
		    "ipmi_smi_setup_con: Unable to allocate os handler\n");
	    return 1;
	}

	sel = ipmi_posix_os_handler_get_sel(os_hnd);
    }

    /* Initialize the OpenIPMI library. */
    ipmi_init(os_hnd);

#ifdef HAVE_UCDSNMP
    if (init_snmp) {
	if (snmp_init(sel) < 0)
	    return 1;
    }
#endif

    rv = ipmi_cmdlang_init(os_hnd);
    if (rv) {
	fprintf(stderr, "Unable to initialize command processor: 0x%x\n", rv);
	return 1;
    }

    setup_cmds();

    setup_term(os_hnd, sel);

    while (execs) {
	exec_list_t *e = execs;
	int         cdone = 0;
	read_nest = 1;
	execs = e->next;
	printf("> %s\n", e->str);
	done_ptr = &cdone;
	ipmi_cmdlang_handle(&cmdlang, e->str);
	while (!cdone)
	    os_hnd->perform_one_op(os_hnd, NULL);
	done_ptr = NULL;
	free(e);
	read_nest = 0;
    }

    printf("> ");
    fflush(stdout);

    handling_input = 1;
    sel_set_fd_read_handler(sel, 0, SEL_FD_HANDLER_ENABLED);

    while (!done)
	os_hnd->perform_one_op(os_hnd, NULL);

    cleanup_term(os_hnd, sel);

    /* Shut down all existing domains. */
    
    done = 0;
    ipmi_domain_iterate_domains(shutdown_domain_handler, &done);
    while (done)
	os_hnd->perform_one_op(os_hnd, NULL);

    ipmi_cmdlang_cleanup();
    ipmi_shutdown();

    os_hnd->free_os_handler(os_hnd);

    ipmi_debug_malloc_cleanup();

    if (evcount)
	printf("\n");

    if (rv)
	return 1;
    return 0;
}