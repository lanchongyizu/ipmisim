
%module OpenIPMI

%{
#include <OpenIPMI/ipmiif.h>
#include <OpenIPMI/ipmi_mc.h>
#include <OpenIPMI/ipmi_msgbits.h>
#include <OpenIPMI/ipmi_conn.h>
#include <OpenIPMI/ipmi_posix.h>
#include <OpenIPMI/ipmi_glib.h>
#include <OpenIPMI/ipmi_debug.h>

#include "OpenIPMI.h"

typedef struct intarray
{
    int *val;
    int len;
} intarray;

os_handler_t *swig_os_hnd;

swig_cb_val swig_log_handler;

void
posix_vlog(char *format, enum ipmi_log_type_e log_type, va_list ap)
{
    char *pfx = "";
    static char log[1024];
    static int curr = 0;
    swig_cb_val handler = swig_log_handler;

    if (! handler)
	return;

    switch(log_type)
    {
    case IPMI_LOG_INFO:
	pfx = "INFO";
	break;

    case IPMI_LOG_WARNING:
	pfx = "WARN";
	break;

    case IPMI_LOG_SEVERE:
	pfx = "SEVR";
	break;

    case IPMI_LOG_FATAL:
	pfx = "FATL";
	break;

    case IPMI_LOG_ERR_INFO:
	pfx = "EINF";
	break;

    case IPMI_LOG_DEBUG:
	pfx = "DEBG";
	break;

    case IPMI_LOG_DEBUG_START:
    case IPMI_LOG_DEBUG_CONT:
	if (curr < sizeof(log))
	    curr += vsnprintf(log+curr, sizeof(log)-curr, format, ap);
	return;

    case IPMI_LOG_DEBUG_END:
	if (curr < sizeof(log))
	    vsnprintf(log+curr, sizeof(log)-curr, format, ap);
	pfx = "DEBG";
	curr = 0;
	goto plog;
    }

    vsnprintf(log, sizeof(log), format, ap);

 plog:
    swig_call_cb(handler, "log", "%s%s", pfx, log);
}

#ifdef HAVE_GLIB
#include <glib.h>
static void
glib_handle_log(const gchar *log_domain,
		GLogLevelFlags log_level,
		const gchar *message,
		gpointer user_data)
{
    char *pfx = "";
    swig_cb_val handler = swig_log_handler;

    if (! handler)
	return;

    if (log_level & G_LOG_LEVEL_ERROR)
	pfx = "FATL";
    else if (log_level & G_LOG_LEVEL_CRITICAL)
	pfx = "SEVR";
    else if (log_level & G_LOG_LEVEL_WARNING)
	pfx = "WARN";
    else if (log_level & G_LOG_LEVEL_MESSAGE)
	pfx = "EINF";
    else if (log_level & G_LOG_LEVEL_INFO)
	pfx = "INFO";
    else if (log_level & G_LOG_LEVEL_DEBUG)
	pfx = "DEBG";

    swig_call_cb(handler, "log", "%s%s", pfx, message);
}
#endif

static int
next_parm(char *s, int *start, int *next)
{
    while (s[*start] && isspace(s[*start]))
	(*start)++;
    if (!s[*start])
	return EINVAL;

    *next = *start;
    while (s[*next] && !isspace(s[*next]))
	(*next)++;
    return 0;
}

static int
next_colon_parm(char *s, int *start, int *next)
{
    while (s[*start] && (s[*start] == ':'))
	(*start)++;
    if (!s[*start])
	return EINVAL;

    *next = *start;
    while (s[*next] && (s[*next] != ':'))
	(*next)++;
    return 0;
}

static int
num_parm(char *s, int len, int *rval)
{
    char numstr[10];
    char *end;
    int  val;

    if (len > 9)
	return EINVAL;
    memcpy(numstr, s, len);
    numstr[len] = '\0';
    val = strtoul(numstr, &end, 0);
    if (*end != '\0')
	return EINVAL;
    *rval = val;
    return 0;
}

static int
parse_ipmi_addr(char *addr, int lun, ipmi_addr_t *i, unsigned int *addr_len)
{
    int start, next;
    int rv;
    int num;
    int len;

    start = 0;
    rv = next_parm(addr, &start, &next);
    if (rv)
	return rv;
    len = next - start;

    if (strncmp(addr+start, "smi", len) == 0) {
	ipmi_system_interface_addr_t *si = (void *) i;

	si->addr_type = IPMI_SYSTEM_INTERFACE_ADDR_TYPE;
	si->lun = lun;
	start = next;
	rv = next_parm(addr, &start, &next);
	if (rv)
	    return rv;
	len = next - start;
	rv = num_parm(addr+start, len, &num);
	if (rv)
	    return rv;
	si->channel = num;
	*addr_len = sizeof(*si);
    } else if (strncmp(addr+start, "ipmb", len) == 0) {
	ipmi_ipmb_addr_t *ipmb = (void *) i;

	ipmb->addr_type = IPMI_IPMB_ADDR_TYPE;
	ipmb->lun = lun;

	start = next;
	rv = next_parm(addr, &start, &next);
	if (rv)
	    return rv;
	len = next - start;
	rv = num_parm(addr+start, len, &num);
	if (rv)
	    return rv;
	ipmb->channel = num;

	start = next;
	rv = next_parm(addr, &start, &next);
	if (rv)
	    return rv;
	len = next - start;
	rv = num_parm(addr+start, len, &num);
	if (rv)
	    return rv;
	ipmb->slave_addr = num;

	*addr_len = sizeof(*ipmb);
    } else {
	return EINVAL;
    }

    return 0;
}

static void
make_ipmi_addr(char *out, int max_len, ipmi_addr_t *addr, int addr_len,
	       int *lun)
{
    if (addr->addr_type == IPMI_SYSTEM_INTERFACE_ADDR_TYPE) {
	ipmi_system_interface_addr_t *si = (void *) addr;
	snprintf(out, max_len, "smi %d", si->channel);
	*lun = si->lun;
    } else if (addr->addr_type == IPMI_IPMB_ADDR_TYPE) {
	ipmi_ipmb_addr_t *ipmb = (void *) addr;
	snprintf(out, max_len, "ipmb %d %d", ipmb->channel, ipmb->slave_addr);
	*lun = ipmb->lun;
    } else {
	strncpy(out, "unknown", max_len);
	*lun = 0;
    }
}

static int
parse_ipmi_data(intarray data, unsigned char *odata,
		unsigned int max_len,
		unsigned int *rlen)
{
    int i;
    if (data.len > max_len)
	return E2BIG;
    for (i=0; i<data.len; i++)
	odata[i] = data.val[i];
    *rlen = data.len;
    return 0;
}

%}

%nodefault;

%typemap(in) swig_cb {
    if (!SvROK($input))
	croak("Argument $argnum is not a reference.");
    $1 = $input;
}

%typemap(in) intarray {
    AV *tempav;
    I32 len;
    int i;
    SV  **tv;
    if (!SvROK($input))
	croak("Argument $argnum is not a reference.");
    if (SvTYPE(SvRV($input)) != SVt_PVAV)
	croak("Argument $argnum is not an array.");
    tempav = (AV*)SvRV($input);
    len = av_len(tempav);
    $1.val = (int *) malloc((len+2)*sizeof(int));
    $1.len = len + 1;
    
    for (i = 0; i <= len; i++) {
	tv = av_fetch(tempav, i, 0);
	$1.val[i] = SvIV(*tv);
    }
}

%typemap(freearg) intarray {
        free($1.val);
};

%typemap(out) intarray {
    AV *tempav;
    SV **svs;
    int i;

    svs = (SV **) malloc($1.len*sizeof(SV *));
    for (i=0; i<$1.len; i++) {
	svs[i] = sv_newmortal();
	sv_setiv(svs[i], $1.val[i]);
    }
    tempav = av_make($1.len, svs);
    free(svs);
    $result = newRV((SV *) tempav);
    sv_2mortal($result);
    argvi++;
}

%typemap(in) char ** {
    AV *tempav;
    I32 len;
    int i;
    SV  **tv;
    if (!SvROK($input))
	croak("Argument $argnum is not a reference.");
    if (SvTYPE(SvRV($input)) != SVt_PVAV)
	croak("Argument $argnum is not an array.");
    tempav = (AV*)SvRV($input);
    len = av_len(tempav);
    $1 = (char **) malloc((len+2)*sizeof(char *));
    for (i = 0; i <= len; i++) {
	tv = av_fetch(tempav, i, 0);
	$1[i] = (char *) SvPV(*tv,PL_na);
    }
    $1[i] = NULL;
};

%typemap(freearg) char ** {
        free($1);
};

%{

#define swig_free_ref_check(r, c) \
	do {								\
	    if (SvREFCNT(SvRV(r.val)) != 1)				\
		warn("***You cannot keep pointers of class %s", c);	\
	    swig_free_ref(r);						\
	} while(0)

static void
handle_domain_cb(ipmi_domain_t *domain, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "domain_cb", "%p", &domain_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
}

static void
domain_connect_change_handler(ipmi_domain_t *domain,
			      int           err,
			      unsigned int  conn_num,
			      unsigned int  port_num,
			      int           still_connected,
			      void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "conn_change_cb", "%p%d%d%d%d",
		 &domain_ref, err, conn_num, port_num, still_connected);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
}

static void
domain_iterate_connections_handler(ipmi_domain_t *domain, int conn,
				   void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "domain_iter_connection_cb", "%p%d", &domain_ref, conn);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
}

static void
domain_event_handler(ipmi_domain_t *domain, ipmi_event_t *event, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;
    swig_ref    event_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "event_cb", "%p%p", &domain_ref, &event_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    swig_free_ref(event_ref);
}

static void
domain_mc_updated_handler(enum ipmi_update_e op, ipmi_domain_t *domain,
			  ipmi_mc_t *mc, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;
    swig_ref    mc_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_update_cb", "%s%p%p",
		 ipmi_update_e_string(op), &domain_ref, &mc_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
}

static void
domain_entity_update_handler(enum ipmi_update_e op, ipmi_domain_t *domain,
			      ipmi_entity_t *entity, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;
    swig_ref    entity_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_update_cb", "%s%p%p",
		 ipmi_update_e_string(op), &domain_ref, &entity_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
}

static void
domain_fully_up(ipmi_domain_t *domain, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "domain_up_cb", "%p", &domain_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
domain_close_done(void *cb_data)
{
    swig_cb_val cb = cb_data;

    swig_call_cb(cb, "close_done_cb", " ");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
domain_iterate_entities_handler(ipmi_entity_t *entity, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;
    swig_ref    entity_ref;

    domain_ref = swig_make_ref(ipmi_entity_get_domain(entity),
			       "OpenIPMI::ipmi_domain_t");
    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_iter_cb", "%p%p", &domain_ref, &entity_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
}

static void
ipmb_mc_scan_handler(ipmi_domain_t *domain, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "ipmb_mc_scan_cb", "%p%i", &domain_ref, err);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
domain_reread_sels_handler(ipmi_domain_t *domain, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "reread_sels_cb", "%p%i", &domain_ref, err);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
}

static int
domain_msg_cb(ipmi_domain_t *domain, ipmi_msgi_t *rspi)
{
    swig_cb_val   cb = rspi->data1;
    swig_ref      domain_ref;
    ipmi_msg_t    *msg = &rspi->msg;
    ipmi_addr_t   *addr = &rspi->addr;
    int           addr_len = rspi->addr_len;
    char          addr_str[50];
    int           lun;

    make_ipmi_addr(addr_str, sizeof(addr_str), addr, addr_len, &lun);
    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    swig_call_cb(cb, "addr_cmd_cb", "%p%s%d%d%d%*s", &domain_ref, addr_str,
		 lun, msg->netfn, msg->cmd, msg->data_len, msg->data);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
    
    return IPMI_MSG_ITEM_NOT_USED;
}

static void
domain_iterate_mcs_handler(ipmi_domain_t *domain, ipmi_mc_t *mc, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    domain_ref;
    swig_ref    mc_ref;

    domain_ref = swig_make_ref(domain, "OpenIPMI::ipmi_domain_t");
    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "domain_iter_mcs_cb", "%p%p", &domain_ref, &mc_ref);
    swig_free_ref_check(domain_ref, "OpenIPMI::ipmi_domain_t");
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
}

static void
handle_entity_cb(ipmi_entity_t *entity, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_cb", "%p", &entity_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
}

static void
entity_iterate_entities_handler(ipmi_entity_t *ent1,
				ipmi_entity_t *ent2,
				void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    ent1_ref;
    swig_ref    ent2_ref;

    ent1_ref = swig_make_ref(ent1, "OpenIPMI::ipmi_entity_t");
    ent2_ref = swig_make_ref(ent2, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_iter_entities_cb", "%p%p", &ent1_ref, &ent2_ref);
    swig_free_ref_check(ent2_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref_check(ent1_ref, "OpenIPMI::ipmi_entity_t");
}

static void
entity_iterate_sensors_handler(ipmi_entity_t *entity,
			       ipmi_sensor_t *sensor,
			       void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    sensor_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "entity_iter_sensors_cb", "%p%p",
		 &entity_ref, &sensor_ref);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
}

static void
entity_iterate_controls_handler(ipmi_entity_t  *entity,
				ipmi_control_t *control,
				void           *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    control_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "entity_iter_controls_cb", "%p%p",
		 &entity_ref, &control_ref);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
}

static int
entity_presence_handler(ipmi_entity_t *entity,
			int           present,
			void          *cb_data,
			ipmi_event_t  *event)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    event_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "entity_presence_cb", "%p%i%p",
		 &entity_ref, present, &event_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref(event_ref);
    return IPMI_EVENT_NOT_HANDLED;
}

static void
entity_sensor_update_handler(enum ipmi_update_e op,
			     ipmi_entity_t      *entity,
			     ipmi_sensor_t      *sensor,
			     void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    sensor_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "entity_sensor_cb", "%s%p%p",
		 ipmi_update_e_string(op), &entity_ref, &sensor_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void
entity_control_update_handler(enum ipmi_update_e op,
			      ipmi_entity_t      *entity,
			      ipmi_control_t     *control,
			      void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    control_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "entity_control_cb", "%s%p%p",
		 ipmi_update_e_string(op), &entity_ref, &control_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static void
entity_fru_update_handler(enum ipmi_update_e op,
			  ipmi_entity_t      *entity,
			  void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    fru_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    fru_ref = swig_make_ref(ipmi_entity_get_fru, "OpenIPMI::ipmi_fru_t");
    swig_call_cb(cb, "entity_fru_cb", "%s%p%p",
		 ipmi_update_e_string(op), &entity_ref, &fru_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref_check(fru_ref, "OpenIPMI::ipmi_fru_t");
}

static int
entity_hot_swap_handler(ipmi_entity_t             *entity,
			enum ipmi_hot_swap_states last_state,
			enum ipmi_hot_swap_states curr_state,
			void                      *cb_data,
			ipmi_event_t              *event)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;
    swig_ref    event_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "entity_hot_swap_update_cb", "%p%s%s%p", &entity_ref,
		 ipmi_hot_swap_state_name(last_state),
		 ipmi_hot_swap_state_name(curr_state),
		 &event_ref);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    swig_free_ref(event_ref);
    return IPMI_EVENT_NOT_HANDLED;
}

static void
entity_get_hot_swap_handler(ipmi_entity_t             *entity,
			    int                       err,
			    enum ipmi_hot_swap_states state,
			    void                      *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_hot_swap_update_cb", "%p%i%s", &entity_ref,
		 err, ipmi_hot_swap_state_name(state));
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
entity_get_hot_swap_time_handler(ipmi_entity_t  *entity,
				 int            err,
				 ipmi_timeout_t time,
				 void           *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_hot_swap_get_time_cb", "%p%i%f", &entity_ref,
		 err, ((double) time) / 1000000000.0);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
entity_set_hot_swap_time_handler(ipmi_entity_t  *entity,
				 int            err,
				 void           *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_hot_swap_set_time_cb", "%p%i", &entity_ref, err);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
entity_activate_handler(ipmi_entity_t  *entity,
			int            err,
			void           *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    entity_ref;

    entity_ref = swig_make_ref(entity, "OpenIPMI::ipmi_entity_t");
    swig_call_cb(cb, "entity_activate_cb", "%p%i", &entity_ref, err);
    swig_free_ref_check(entity_ref, "OpenIPMI::ipmi_entity_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
handle_mc_cb(ipmi_mc_t *mc, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_cb", "%p", &mc_ref);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
}

static void
mc_active_handler(ipmi_mc_t  *mc,
		  int        active,
		  void       *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_active_cb", "%p%i", &mc_ref, active);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
}

static void
mc_msg_cb(ipmi_mc_t  *mc,
	  ipmi_msg_t *msg,
	  void       *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_cmd_cb", "%p%d%d%*s", &mc_ref,
		 msg->netfn, msg->cmd, msg->data_len, msg->data);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
mc_reset_handler(ipmi_mc_t *mc, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_reset_cb", "%p%d", &mc_ref, err);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
mc_events_enable_handler(ipmi_mc_t *mc, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_events_enable_cb", "%p%d", &mc_ref, err);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
mc_reread_sensors_handler(ipmi_mc_t *mc, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_reread_sensors_cb", "%p%d", &mc_ref, err);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
mc_reread_sel_handler(ipmi_mc_t *mc, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_reread_sel_cb", "%p%d", &mc_ref, err);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
mc_sel_get_time_cb(ipmi_mc_t     *mc,
		   int           err,
		   unsigned long time,
		   void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    mc_ref;

    mc_ref = swig_make_ref(mc, "OpenIPMI::ipmi_mc_t");
    swig_call_cb(cb, "mc_reread_sel_cb", "%p%d%ld", &mc_ref, err, time);
    swig_free_ref_check(mc_ref, "OpenIPMI::ipmi_mc_t");
    /* One-time call, get rid of the CB. */
    deref_swig_cb_val(cb);
}

static void
handle_sensor_cb(ipmi_sensor_t *sensor, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_cb", "%p", &sensor_ref);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static char *
threshold_str(char *s, enum ipmi_thresh_e thresh)
{
    if (thresh == IPMI_UPPER_NON_CRITICAL) {
	*s = 'u'; s++; *s = 'n'; s++;
    } else if (thresh == IPMI_UPPER_CRITICAL) {
	*s = 'u'; s++; *s = 'c'; s++;
    } else if (thresh == IPMI_UPPER_NON_RECOVERABLE) {
	*s = 'u'; s++; *s = 'r'; s++;
    } else if (thresh == IPMI_UPPER_NON_CRITICAL) {
	*s = 'l'; s++; *s = 'n'; s++;
    } else if (thresh == IPMI_UPPER_CRITICAL) {
	*s = 'l'; s++; *s = 'c'; s++;
    } else if (thresh == IPMI_UPPER_NON_RECOVERABLE) {
	*s = 'l'; s++; *s = 'r'; s++;
    }
    return s;
}

static char *
threshold_from_str(char *s, int len, enum ipmi_thresh_e *thresh)
{
    if (len != 2)
	return NULL;

    if (strncasecmp(s, "un", 2) == 0)
	*thresh = IPMI_UPPER_NON_CRITICAL;
    else if (strncasecmp(s, "uc", 2) == 0)
	*thresh = IPMI_UPPER_CRITICAL;
    else if (strncasecmp(s, "ur", 2) == 0)
	*thresh = IPMI_UPPER_NON_RECOVERABLE;
    else if (strncasecmp(s, "ln", 2) == 0)
	*thresh = IPMI_LOWER_NON_CRITICAL;
    else if (strncasecmp(s, "lc", 2) == 0)
	*thresh = IPMI_LOWER_CRITICAL;
    else if (strncasecmp(s, "lr", 2) == 0)
	*thresh = IPMI_LOWER_NON_RECOVERABLE;
    else
	return NULL;
    return s+2;
}

static char *
threshold_event_str(char                        *s, 
		    enum ipmi_thresh_e          thresh,
		    enum ipmi_event_value_dir_e value_dir,
		    enum ipmi_event_dir_e       dir)
{
    s = threshold_str(s, thresh);
    if (value_dir == IPMI_GOING_HIGH) {
	*s = 'h'; s++;
    } else {
	*s = 'l'; s++;
    }
    if (dir == IPMI_ASSERTION) {
	*s = 'a'; s++;
    } else {
	*s = 'd'; s++;
    }
    return s;
}

static char *
threshold_event_from_str(char                        *s,
			 int                        len,
			 enum ipmi_thresh_e          *thresh,
			 enum ipmi_event_value_dir_e *value_dir,
			 enum ipmi_event_dir_e       *dir)
{
    if (len != 4)
	return NULL;

    s = threshold_from_str(s, 2, thresh);

    if (*s == 'l')
	*value_dir = IPMI_GOING_LOW;
    else if (*s == 'h')
	*value_dir = IPMI_GOING_HIGH;
    else
	return NULL;
    s++;
    if (*s == 'a')
	*dir = IPMI_ASSERTION;
    else if (*s == 'd')
	*dir = IPMI_DEASSERTION;
    else
	return NULL;
    s++;
    return s;
}

static char *
discrete_event_from_str(char                  *s,
			int                   len,
			int                   *offset,
			enum ipmi_event_dir_e *dir)
{
    if ((len < 2) || (len > 3))
	return NULL;

    *offset = strtoul(s, &s, 0);
    if (*offset >= 15)
	return NULL;
    if (*s == 'a')
	*dir = IPMI_ASSERTION;
    else if (*s == 'd')
	*dir = IPMI_DEASSERTION;
    else
	return NULL;
    s++;
    return s;
}

static char *
discrete_event_str(char                   *s, 
		   int                    offset,
		   enum ipmi_event_dir_e dir)
{
    if (offset >= 100)
	offset = 99;
    if (offset < 0)
	offset = 0;
    sprintf(s, "%d", offset);
    s += 2;
    if (dir == IPMI_ASSERTION) {
	*s = 'a'; s++;
    } else {
	*s = 'd'; s++;
    }
    return s;
}

static char *
threshold_event_state_to_str(ipmi_event_state_t *events)
{
    int                         len = 0;
    char                        *str;
    enum ipmi_thresh_e          thresh;
    enum ipmi_event_value_dir_e value_dir;
    enum ipmi_event_dir_e       dir;
    char                        *s;

    if (ipmi_event_state_get_events_enabled(events))
	len += strlen("events ");
    if (ipmi_event_state_get_scanning_enabled(events))
	len += strlen("scanning ");
    if (ipmi_event_state_get_busy(events))
	len += strlen("busy ");

    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	for (value_dir = IPMI_GOING_LOW;
	     value_dir <= IPMI_GOING_HIGH;
	     value_dir++)
	{
	    for (dir = IPMI_ASSERTION;
		 dir <= IPMI_DEASSERTION;
		 dir++)
	    {
		if (ipmi_is_threshold_event_set(events,thresh, value_dir, dir))
		    len += 5;
	    }
	}
    }

    str = malloc(len+1);
    
    if (ipmi_event_state_get_events_enabled(events))
	strcat("events ", str);
    if (ipmi_event_state_get_scanning_enabled(events))
	strcat("scanning ", str);
    if (ipmi_event_state_get_busy(events))
	strcat("busy ", str);
    s = str + strlen(str);

    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	for (value_dir = IPMI_GOING_LOW;
	     value_dir <= IPMI_GOING_HIGH;
	     value_dir++)
	{
	    for (dir = IPMI_ASSERTION;
		 dir <= IPMI_DEASSERTION;
		 dir++)
	    {
		if (!ipmi_is_threshold_event_set(events,thresh,value_dir,dir))
		    continue;

		s = threshold_event_str(s, thresh, value_dir, dir);
		*s = ' ';
		s++;
	    }
	}
    }
    *s = '\0';

    len = s - str;
    if (len > 0)
	str[len-1] = '\0'; /* Remove the final space */

    return str;
}

static int
str_to_threshold_event_state(char               *str,
			     ipmi_event_state_t **events)
{
    enum ipmi_thresh_e          thresh;
    enum ipmi_event_value_dir_e value_dir;
    enum ipmi_event_dir_e       dir;
    ipmi_event_state_t          *e;
    int                         start, next;
    int                         rv;

    e = malloc(ipmi_event_state_size());
    ipmi_event_state_init(e);

    start = 0;
    rv = next_parm(str, &start, &next);
    while (!rv) {
	char *s = str+start;
	int  len = next - start;
	if (strncasecmp(s, "events", len) == 0)
	    ipmi_event_state_set_events_enabled(e, 1);
	else if (strncasecmp(s, "scanning", len) == 0)
	    ipmi_event_state_set_scanning_enabled(e, 1);
	else if (strncasecmp(s, "busy", len) == 0)
	    ipmi_event_state_set_busy(e, 1);
	else {
	    s = threshold_event_from_str(s, len, &thresh, &value_dir, &dir);
	    if (!s)
		goto out_err;

	    ipmi_threshold_event_set(e, thresh, value_dir, dir);
	}

	start = next;
	rv = next_parm(str, &start, &next);
    }

    return 0;

 out_err:
    free(e);
    return EINVAL;
}

static char *
discrete_event_state_to_str(ipmi_event_state_t *events)
{
    int                   len = 0;
    char                  *str;
    int                   offset;
    enum ipmi_event_dir_e dir;
    char                  *s;

    if (ipmi_event_state_get_events_enabled(events))
	len += strlen("events ");
    if (ipmi_event_state_get_scanning_enabled(events))
	len += strlen("scanning ");
    if (ipmi_event_state_get_busy(events))
	len += strlen("busy ");

    for (offset=0; offset<15; offset++) {
	for (dir = IPMI_ASSERTION;
	     dir <= IPMI_DEASSERTION;
	     dir++)
	{
	    if (ipmi_is_discrete_event_set(events, offset, dir))
		    len += 4;
	}
    }

    str = malloc(len+1);
    
    if (ipmi_event_state_get_events_enabled(events))
	strcat("events ", str);
    if (ipmi_event_state_get_scanning_enabled(events))
	strcat("scanning ", str);
    if (ipmi_event_state_get_busy(events))
	strcat("busy ", str);
    s = str + strlen(str);

    for (offset=0; offset<15; offset++) {
	for (dir = IPMI_ASSERTION;
	     dir <= IPMI_DEASSERTION;
	     dir++)
	{
	    if (! ipmi_is_discrete_event_set(events, offset, dir))
		continue;

	    s = discrete_event_str(s, offset, dir);
	    *s = ' ';
	    s++;
	}
    }
    *s = '\0';

    len = s - str;
    if (len > 0)
	str[len-1] = '\0'; /* Remove the final space */

    return str;
}

static int
str_to_discrete_event_state(char               *str,
			    ipmi_event_state_t **events)
{
    int                   offset;
    enum ipmi_event_dir_e dir;
    ipmi_event_state_t    *e;
    int                   start, next;
    int                   rv;

    e = malloc(ipmi_event_state_size());
    ipmi_event_state_init(e);

    start = 0;
    rv = next_parm(str, &start, &next);
    while (!rv) {
	char *s = str+start;
	int  len = next - start;
	if (strncasecmp(s, "events", len) == 0)
	    ipmi_event_state_set_events_enabled(e, 1);
	else if (strncasecmp(s, "scanning", len) == 0)
	    ipmi_event_state_set_scanning_enabled(e, 1);
	else if (strncasecmp(s, "busy", len) == 0)
	    ipmi_event_state_set_busy(e, 1);
	else {
	    s = discrete_event_from_str(s, len, &offset, &dir);
	    if (!s)
		goto out_err;
	    ipmi_discrete_event_set(e, offset, dir);
	}
	start = next;
	rv = next_parm(str, &start, &next);
    }

    *events = e;
    return 0;

 out_err:
    free(e);
    return EINVAL;
}

static char *
threshold_states_to_str(ipmi_states_t *states)
{
    int                len = 0;
    char               *str;
    enum ipmi_thresh_e thresh;
    char               *s;

    if (ipmi_is_event_messages_enabled(states))
	len += strlen("events ");
    if (ipmi_is_sensor_scanning_enabled(states))
	len += strlen("scanning ");
    if (ipmi_is_initial_update_in_progress(states))
	len += strlen("busy ");

    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	if (ipmi_is_threshold_out_of_range(states, thresh))
	    len += 3;
    }

    str = malloc(len+1);
    
    if (ipmi_is_event_messages_enabled(states))
	strcat("events ", str);
    if (ipmi_is_sensor_scanning_enabled(states))
	strcat("scanning ", str);
    if (ipmi_is_initial_update_in_progress(states))
	strcat("busy ", str);
    s = str + strlen(str);

    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	if (!ipmi_is_threshold_out_of_range(states, thresh))
	    continue;

	s = threshold_str(s, thresh);
	*s = ' ';
	s++;
    }
    *s = '\0';

    len = s - str;
    if (len > 0)
	str[len-1] = '\0'; /* Remove the final space */

    return str;
}

static char *
discrete_states_to_str(ipmi_states_t *states)
{
    int  len = 0;
    char *str;
    int  offset;
    char *s;

    if (ipmi_is_event_messages_enabled(states))
	len += strlen("events ");
    if (ipmi_is_sensor_scanning_enabled(states))
	len += strlen("scanning ");
    if (ipmi_is_initial_update_in_progress(states))
	len += strlen("busy ");

    for (offset=0; offset<15; offset++) {
	if (ipmi_is_state_set(states, offset))
	    len += 3;
    }

    str = malloc(len+1);
    
    if (ipmi_is_event_messages_enabled(states))
	strcat("events ", str);
    if (ipmi_is_sensor_scanning_enabled(states))
	strcat("scanning ", str);
    if (ipmi_is_initial_update_in_progress(states))
	strcat("busy ", str);
    s = str + strlen(str);

    for (offset=0; offset<15; offset++) {
	if (! ipmi_is_state_set(states, offset))
	    continue;

	s += sprintf(s, "%d", offset);
	*s = ' ';
	s++;
    }
    *s = '\0';

    len = s - str;
    if (len > 0)
	str[len-1] = '\0'; /* Remove the final space */

    return str;
}

static char *
thresholds_to_str(ipmi_thresholds_t *t)
{
    int                len = 0;
    char               *str;
    enum ipmi_thresh_e thresh;
    char               dummy[3];
    char               *s;
    double             val;

    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	if (ipmi_threshold_get(t, thresh, &val) == 0)
	    len += snprintf(dummy, 1, "aa %f:", val);
    }

    str = malloc(len+1);
    s = str;
    
    len = 0;
    for (thresh = IPMI_LOWER_NON_CRITICAL;
	 thresh <= IPMI_UPPER_NON_RECOVERABLE; 
	 thresh++)
    {
	if (ipmi_threshold_get(t, thresh, &val) != 0)
	    continue;

	threshold_str(dummy, thresh);

	s += sprintf(s, "%s %f:", dummy, val);
	*s = ' ';
	s++;
    }
    *s = '\0';

    len = s - str;
    if (len > 0)
	str[len-1] = '\0'; /* Remove the final : */

    return str;
}

static int
str_to_thresholds(char              *str,
		  ipmi_thresholds_t **thresholds)
{
    enum ipmi_thresh_e thresh;
    ipmi_thresholds_t  *t;
    int                start, next;
    int                rv;
    double             val;

    t = malloc(ipmi_thresholds_size());
    ipmi_thresholds_init(t);

    start = 0;
    rv = next_colon_parm(str, &start, &next);
    while (!rv) {
	char *s = str+start;
	char *endstr;
	int  len = next - start;
	if (len < 4)
	    goto out_err;

	if (strncasecmp(s, "un ", 3) == 0)
	    thresh = IPMI_UPPER_NON_CRITICAL;
	else if (strncasecmp(s, "uc ", 3) == 0)
	    thresh = IPMI_UPPER_CRITICAL;
	else if (strncasecmp(s, "ur ", 3) == 0)
	    thresh = IPMI_UPPER_NON_RECOVERABLE;
	else if (strncasecmp(s, "ln ", 3) == 0)
	    thresh = IPMI_LOWER_NON_CRITICAL;
	else if (strncasecmp(s, "lc ", 3) == 0)
	    thresh = IPMI_LOWER_CRITICAL;
	else if (strncasecmp(s, "lr ", 3) == 0)
	    thresh = IPMI_LOWER_NON_RECOVERABLE;
	else
	    goto out_err;
	    
	val = strtod(s+3, &endstr);
	if (*endstr != ':')
	    goto out_err;

	start = next;
	rv = next_parm(str, &start, &next);
    }

    *thresholds = t;
    return 0;

 out_err:
    free(t);
    return EINVAL;
}

static int
sensor_threshold_event_handler(ipmi_sensor_t               *sensor,
			       enum ipmi_event_dir_e       dir,
			       enum ipmi_thresh_e          threshold,
			       enum ipmi_event_value_dir_e high_low,
			       enum ipmi_value_present_e   value_present,
			       unsigned int                raw_value,
			       double                      value,
			       void                        *cb_data,
			       ipmi_event_t                *event)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    char        eventstr[5];
    int         raw_set = 0;
    int         value_set = 0;
    swig_ref    event_ref;

    if (value_present == IPMI_RAW_VALUE_PRESENT)
	raw_set = 1;
    if (value_present == IPMI_BOTH_VALUES_PRESENT) {
	raw_set = 1;
	value_set = 1;
    }
    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    threshold_event_str(eventstr, threshold, high_low, dir);
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "threshold_event_cb", "%p%s%d%d%d%f%p", &sensor_ref,
		 eventstr, raw_set, raw_value, value_set, value, &event_ref);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    swig_free_ref(event_ref);
    return IPMI_EVENT_NOT_HANDLED;
}

static int
sensor_discrete_event_handler(ipmi_sensor_t         *sensor,
			      enum ipmi_event_dir_e dir,
			      int                   offset,
			      int                   severity,
			      int                   prev_severity,
			      void                  *cb_data,
			      ipmi_event_t          *event)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    char        eventstr[5];
    swig_ref    event_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    discrete_event_str(eventstr, offset, dir);
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "threshold_event_cb", "%p%s%d%d%p", &sensor_ref,
		 eventstr, severity, prev_severity, &event_ref);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    swig_free_ref(event_ref);
    return IPMI_EVENT_NOT_HANDLED;
}

/* A generic callback for a lot of things. */
static void
sensor_event_enable_handler(ipmi_sensor_t *sensor,
			    int           err,
			    void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_event_enable_cb", "%p%d", &sensor_ref, err);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void
sensor_get_event_enables_handler(ipmi_sensor_t      *sensor,
				 int                err,
				 ipmi_event_state_t *states,
				 void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    char        *st;

    if (ipmi_sensor_get_event_reading_type(sensor)
	== IPMI_EVENT_READING_TYPE_THRESHOLD)
    {
	st = threshold_event_state_to_str(states);
    } else {
	st = discrete_event_state_to_str(states);
    }

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_get_event_enable_cb", "%p%d%s",
		 &sensor_ref, err, st);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    free(st);
}

static void
sensor_rearm_handler(ipmi_sensor_t      *sensor,
		     int                err,
		     void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_rearm_cb", "%p%d", &sensor_ref, err);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void
sensor_get_hysteresis_handler(ipmi_sensor_t *sensor,
			      int           err,
			      unsigned int  positive_hysteresis,
			      unsigned int  negative_hysteresis,
			      void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_get_hysteresis_cb", "%p%d%d%d", &sensor_ref, err,
		 positive_hysteresis, negative_hysteresis);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void
sensor_set_hysteresis_handler(ipmi_sensor_t      *sensor,
			      int                err,
			      void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_set_hysteresis_cb", "%p%d", &sensor_ref, err);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void
sensor_set_thresholds_handler(ipmi_sensor_t      *sensor,
			      int                err,
			      void               *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_set_thresholds_cb", "%p%d", &sensor_ref, err);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
}

static void sensor_get_thresholds_handler(ipmi_sensor_t     *sensor,
					  int               err,
					  ipmi_thresholds_t *th,
					  void              *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    char        *thstr = thresholds_to_str(th);

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    swig_call_cb(cb, "sensor_get_thresholds_cb", "%p%d%s", &sensor_ref, err,
		 thstr);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    free(thstr);
}

static void
sensor_get_reading_handler(ipmi_sensor_t             *sensor,
			   int                       err,
			   enum ipmi_value_present_e value_present,
			   unsigned int              raw_value,
			   double                    value,
			   ipmi_states_t             *states,
			   void                      *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    int         raw_set = 0;
    int         value_set = 0;
    char        *statestr;

    if (value_present == IPMI_RAW_VALUE_PRESENT)
	raw_set = 1;
    if (value_present == IPMI_BOTH_VALUES_PRESENT) {
	raw_set = 1;
	value_set = 1;
    }
    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    statestr = threshold_states_to_str(states);
    swig_call_cb(cb, "threshold_reading_cb", "%p%d%d%d%f%s", &sensor_ref,
		 raw_set, raw_value, value_set, value, statestr);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    free(statestr);
}

static void
sensor_get_states_handler(ipmi_sensor_t *sensor,
			  int           err,
			  ipmi_states_t *states,
			  void          *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    sensor_ref;
    char        *statestr;

    sensor_ref = swig_make_ref(sensor, "OpenIPMI::ipmi_sensor_t");
    statestr = discrete_states_to_str(states);
    swig_call_cb(cb, "discrete_states_cb", "%p%d%s", &sensor_ref,
		 err, statestr);
    swig_free_ref_check(sensor_ref, "OpenIPMI::ipmi_sensor_t");
    free(statestr);
}

static int
str_to_color(char *s, int len, int *color)
{
    int i;

    for (i=IPMI_CONTROL_COLOR_BLACK; i<=IPMI_CONTROL_COLOR_ORANGE; i++) {
	if (strncasecmp(s, ipmi_get_color_string(i), len) == 0) {
	    *color = i;
	    return 0;
	}
    }

    return EINVAL;
}

static int
str_to_light_setting(char *s, ipmi_light_setting_t **setting)
{
    int                  rv;
    ipmi_light_setting_t *e;
    int                  start, next;
    int                  count;

    count = 0;
    start = 0;
    rv = next_colon_parm(s, &start, &next);
    while (!rv) {
	start = next;
	rv = next_colon_parm(s, &start, &next);
    }
    if (count == 0)
	return EINVAL;

    e = ipmi_alloc_light_settings(count);

    count = 0;
    start = 0;
    rv = next_colon_parm(s, &start, &next);
    while (!rv) {
	int  color, on_time, off_time;
	char *ms;
	int  mstart, mnext;
	char *endstr;
	char buf[100];
	int  len = next - start;

	if (len >= 100)
	    goto out_err;

	memcpy(buf, s+start, len);
	buf[len] = '\0';

	ms = buf;
	mstart = 0;
	rv = next_parm(ms, &mstart, &mnext);
	if (rv)
	    goto out_err;
	len = mnext - mstart;
	if ((len == 2) && (strncasecmp(ms+mstart, "lc", 2) == 0)) {
	    rv = ipmi_light_setting_set_local_control(e, count, 1);
	    if (rv)
		goto out_err;

	    mstart = mnext;
	    rv = next_parm(ms, &mstart, &mnext);
	    if (rv)
		goto out_err;
	}

	rv = str_to_color(ms+mstart, mnext-mstart, &color);
	if (rv)
	    goto out_err;

	mstart = mnext;
	rv = next_parm(ms, &mstart, &mnext);
	if (rv)
	    goto out_err;
	on_time = strtoul(ms+mstart, &endstr, 0);
	if (endstr != (ms+mnext))
	    goto out_err;

	mstart = mnext;
	rv = next_parm(ms, &mstart, &mnext);
	if (rv)
	    goto out_err;
	off_time = strtoul(ms+mstart, &endstr, 0);
	if (endstr != (ms+mnext))
	    goto out_err;

	rv = ipmi_light_setting_set_color(e, count, color);
	rv |= ipmi_light_setting_set_on_time(e, count, on_time);
	rv |= ipmi_light_setting_set_off_time(e, count, off_time);
	if (rv)
	    goto out_err;

	count++;

	start = next;
	rv = next_colon_parm(s, &start, &next);
    }
    
    *setting = e;
    return 0;

 out_err:
    ipmi_free_light_settings(e);
    return EINVAL;
}

static char *
light_setting_to_str(ipmi_light_setting_t *e)
{
    char *s, *str;
    int  i;
    int  count = ipmi_light_setting_get_count(e);
    char dummy[1];
    int  size = 0;

    for (i=0; i<count; i++) {
	int val;
	size += 1; /* For the colon */
	val = 0;
	ipmi_light_setting_in_local_control(e, i, &val);
	if (val)
	    size += 3;
	val = 0;
	ipmi_light_setting_get_color(e, i, &val);
	size += strlen(ipmi_get_color_string(val)) + 1;
	val = 0;
	ipmi_light_setting_get_on_time(e, i, &val);
	size += snprintf(dummy, 1, "%d ", val);
	val = 0;
	ipmi_light_setting_get_off_time(e, i, &val);
	size += snprintf(dummy, 1, "%d ", val);
    }

    str = malloc(size+1);
    s = str;

    for (i=0; i<count; i++) {
	int val;
	char *ov;

	val = 0;
	ipmi_light_setting_in_local_control(e, i, &val);
	if (val) {
	    strcpy(s, "lc ");
	    s += 3;
	}

	val = 0;
	ipmi_light_setting_get_color(e, i, &val);
	ov = ipmi_get_color_string(val);
	strcpy(s, ov);
	s += strlen(ov);
	*s = ' ';
	s++;

	val = 0;
	ipmi_light_setting_get_on_time(e, i, &val);
	s += sprintf(s, "%d ", val);

	val = 0;
	ipmi_light_setting_get_off_time(e, i, &val);
	s += sprintf(s, "%d", val);

	*s = ':';
	s++;
    }
    if (s != str) {
	/* Remove the final colon. */
	s--;
	*s = '\0';
    } else {
	*s = '\0';
    }

    return str;
}

static void
handle_control_cb(ipmi_control_t *control, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "control_cb", "%p", &control_ref);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static void
control_val_set_handler(ipmi_control_t *control, int err, void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "control_set_val_cb", "%p", &control_ref);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static void
control_val_get_handler(ipmi_control_t *control, int err, int *val,
			void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "control_get_val_cb", "%p%d%*p", &control_ref, err,
		 ipmi_control_get_num_vals(control), val);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static void
control_val_get_light_handler(ipmi_control_t *control, int err,
			      ipmi_light_setting_t *val,
			      void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "control_get_light_cb", "%p%d%s", &control_ref, err,
		 light_setting_to_str(val));
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static void
control_val_get_id_handler(ipmi_control_t *control, int err,
			   unsigned char *val, int length,
			   void *cb_data)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    swig_call_cb(cb, "control_get_id_cb", "%p%d%*s", &control_ref, err,
		 length, val);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
}

static int
control_val_event_handler(ipmi_control_t *control, int *valid_vals, int *val,
			  void *cb_data, ipmi_event_t *event)
{
    swig_cb_val cb = cb_data;
    swig_ref    control_ref;
    swig_ref    event_ref;

    control_ref = swig_make_ref(control, "OpenIPMI::ipmi_control_t");
    event_ref = swig_make_ref_destruct(ipmi_event_dup(event),
				       "OpenIPMI::ipmi_event_t");
    swig_call_cb(cb, "control_event_val_cb", "%p%p%*p%*p", &control_ref,
		 &event_ref,
		 ipmi_control_get_num_vals(control), valid_vals,
		 ipmi_control_get_num_vals(control), val);
    swig_free_ref_check(control_ref, "OpenIPMI::ipmi_control_t");
    swig_free_ref(event_ref);
    return IPMI_EVENT_NOT_HANDLED;
}

%}

typedef struct {
} ipmi_domain_t;

typedef struct {
} ipmi_domain_id_t;

typedef struct {
} ipmi_entity_t;

typedef struct {
} ipmi_entity_id_t;

typedef struct {
} ipmi_fru_t;

typedef struct {
} ipmi_mc_t;

typedef struct {
} ipmi_mcid_t;

typedef struct {
} ipmi_event_t;

typedef struct {
} ipmi_sensor_t;

typedef struct {
} ipmi_sensor_id_t;

typedef struct {
} ipmi_control_t;

typedef struct {
} ipmi_control_id_t;

%newobject open_domain;

%inline %{
/*
 * Initialize the OS handler and use the POSIX version.
 */
void
init_posix(void)
{
    swig_os_hnd = ipmi_posix_setup_os_handler();
    ipmi_init(swig_os_hnd);
}

#ifdef HAVE_GLIB
/*
 * Initialize the OS handler with the glib version.
 */
void
init_glib(void)
{
    swig_os_hnd = ipmi_glib_get_os_handler();
    g_thread_init(NULL);
    ipmi_init(swig_os_hnd);
    g_log_set_handler("OpenIPMI",
		      G_LOG_LEVEL_ERROR
		      | G_LOG_LEVEL_CRITICAL
		      | G_LOG_LEVEL_WARNING
		      | G_LOG_LEVEL_MESSAGE
		      | G_LOG_LEVEL_INFO
		      | G_LOG_LEVEL_DEBUG
		      | G_LOG_FLAG_FATAL,
		      glib_handle_log,
		      NULL);
}

/*
 * Initialize the OS handler with the default version.  This is glib
 * if it is present, POSIX if it is not.
 */
void
init(void)
{
#ifdef HAVE_GLIB
    init_glib();
#else
    init_posix();
#endif
}

#endif

/*
 * Perform one operation.  The first parameter is a timeout in
 * milliseconds.
 */
void
wait_io(int timeout)
{
    struct timeval tv = { (timeout / 1000), ((timeout + 999) % 1000) };
    swig_os_hnd->perform_one_op(swig_os_hnd, &tv);
}
%}

/*
 * A bug in swig (default parameters not used in inline) causes this
 * to have to not be in an inline and done the hard way.
 */
%{
/*
 * Create a new domain.  The domain will be named with the first parm,
 * the startup arguments are in a list in the second parm (\@args),
 * the third parm is a callback object whose conn_change_cb method
 * will be called when the domain has connected (but it may not be
 * fully up yet).  The fourth parameter's domain_up_cb method will be
 * called when the domain is completely up.  Note that the done method
 * will be kept around and will continue to be called on connection
 * changes.  If you don't want it any more, it must be deregistered
 * with remove_connect_change_handler.
 * Passing in a reference to an undefined value will cause the handlers
 * to not be called.
 * The domain_up_cb methods is called with the following parmeters:
 * <domain>
 * The parameters of the connection change handler are defined in
 * the domain->add_connect_change_handler method.
 */
ipmi_domain_id_t *
open_domain(char *name, char **args, swig_cb done, swig_cb up)
{
    int                i, j;
    int                len;
    int                num_options = 0;
    ipmi_open_option_t options[10];
    int                set = 0;
    ipmi_args_t        *con_parms[2];
    ipmi_con_t         *con[2];
    ipmi_domain_id_t   *nd;
    int                rv;
    swig_cb_val        done_val = NULL;
    swig_cb_val        up_val = NULL;
    ipmi_domain_con_cb con_change = NULL;
    ipmi_domain_ptr_cb domain_up = NULL;

    for (len=0; args[len]; len++)
	;

    nd = malloc(sizeof(*nd));

    for (i=0; args[i]; i++) {
	if (num_options >= 10) {
	    free(nd);
	    return NULL;
	}

	if (! ipmi_parse_options(options+num_options, args[i]))
	    num_options++;
	else
	    break;
    }

    rv = ipmi_parse_args(&i, len, args, &con_parms[set]);
    if (rv) {
	free(nd);
	return NULL;
    }
    set++;

    if (i < len) {
	rv = ipmi_parse_args(&i, len, args, &con_parms[set]);
	if (rv) {
	    ipmi_free_args(con_parms[0]);
	    free(nd);
	    return NULL;
	}
	set++;
    }

    for (i=0; i<set; i++) {
	rv = ipmi_args_setup_con(con_parms[i],
				 swig_os_hnd,
				 NULL,
				 &con[i]);
	if (rv) {
	    for (j=0; j<set; j++)
		ipmi_free_args(con_parms[j]);
	    free(nd);
	    return NULL;
	}
    }

    if (valid_swig_cb(up)) {
	up_val = ref_swig_cb(up);
	domain_up = domain_fully_up;
    }
    if (valid_swig_cb(done)) {
	done_val = ref_swig_cb(done);
	con_change = domain_connect_change_handler;
    }
    rv = ipmi_open_domain(name, con, set, con_change, done_val,
			  domain_up, up_val,
			  options, num_options, nd);
    if (rv) {
	if (valid_swig_cb(up))
	    deref_swig_cb(up);
	if (valid_swig_cb(done))
	    deref_swig_cb(done);
	for (i=0; i<set; i++) {
	    ipmi_free_args(con_parms[i]);
	    con[i]->close_connection(con[i]);
	}
	free(nd);
	return NULL;
    }

    for (i=0; i<set; i++)
	ipmi_free_args(con_parms[i]);

    return nd;
}

/*
 * Set the handler for OpenIPMI logs.  The logs will be sent to the
 * "log" method of the first parameter.  The log method will receive
 * the following parameters:
 * <self>, <log_level (a string)>, and <log (a string)>.
 */
void
set_log_handler(swig_cb handler)
{
    swig_cb_val old_handler = swig_log_handler;
    if (valid_swig_cb(handler))
	swig_log_handler = ref_swig_cb(handler);
    else
	swig_log_handler = NULL;
    if (old_handler)
	deref_swig_cb_val(old_handler);
}
%}

ipmi_domain_id_t *open_domain(char *name, char **args,
			      swig_cb done = NULL, swig_cb up = NULL);
void set_log_handler(swig_cb handler = NULL);


/* These two defines simplify the functions that do addition/removal
   of callbacks.  The type is the object type (domain, entity, etc)
   and the name is the stuff in the middle of the name, ie
   (ipmi_<type>_add_<name>_handler.  The function that will be called
   with the info is <type>_<name>_handler. */
#define cb_add(type, name) \
	int         rv;						\
	swig_cb_val handler_val;				\
	if (! valid_swig_cb(handler))				\
	    return EINVAL;					\
	handler_val = ref_swig_cb(handler);			\
	rv = ipmi_ ## type ## _add_ ## name ## _handler		\
	    (self, type ## _ ## name ## _handler, handler_val);	\
	if (rv)							\
	    deref_swig_cb_val(handler_val);			\
	return rv;
#define cb_rm(type, name) \
	int         rv;						\
	swig_cb_val handler_val;				\
	if (! valid_swig_cb(handler))				\
	    return EINVAL;					\
	handler_val = get_swig_cb(handler);			\
	rv = ipmi_ ## type ## _remove_ ## name ##_handler	\
	    (self, type ## _ ## name ## _handler, handler_val);	\
	if (!rv)						\
	    deref_swig_cb_val(handler_val);			\
	return rv;
    

/*
 * A domain id object.  This object is guaranteed to be valid and
 * can be converted into a domain pointer later.
 */
%extend ipmi_domain_id_t {
    ~ipmi_domain_id_t()
    {
	free(self);
    }

    /*
     * Convert a domain id to a domain pointer.  The "domain_cb" method
     * will be called on the first parameter with the following parameters:
     * <self> <domain>
     */
    char *convert_to_domain(swig_cb handler)
    {
	int rv;

	if (! valid_swig_cb(handler))
	    return NULL;

	rv = ipmi_domain_pointer_cb(*self, handle_domain_cb,
				    get_swig_cb(handler));
	if (rv)
	    return strerror(rv);
	return NULL;
    }
}

/*
 * A domain object.
 */
%extend ipmi_domain_t {
    %newobject get_name;
    /*
     * Get the name of the domain.
     */
    char *get_name()
    {
	char name[IPMI_DOMAIN_NAME_LEN];

	ipmi_domain_get_name(self, name, sizeof(name));
	return strdup(name);
    }

    %newobject get_id;
    /*
     * Get the ID of the domain so you can hold on to the reference.
     */
    ipmi_domain_id_t *get_id()
    {
	ipmi_domain_id_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_domain_convert_to_id(self);
	return rv;
    }

    /*
     * Shut down the connections to the domain and free it up.
     * If the parameter given 
     */
    int close(swig_cb handler = NULL)
    {
	int         rv;
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = ref_swig_cb(handler);
	rv = ipmi_domain_close(self, domain_close_done, handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Add a handler to be called when the connection changes status.
     * The conn_change_cb method on the first parameter will be
     * called when the connection changes status with the following
     * parameters: <self>, <domain>, <errorval>, <connection_number>,
     * <port_number>, <still_connected>.
     */
    int add_connect_change_handler(swig_cb handler)
    {
	cb_add(domain, connect_change);
    }

    /*
     * Remove the connection change handler.
     */
    int remove_connect_change_handler(swig_cb handler)
    {
	cb_rm(domain, connect_change);
    }

    /*
     * Iterate through all the connections in the object.  The
     * domain_iter_connection_cb method will be called on the first
     * parameter for each connection in the domain.  The parameters it
     * receives will be: <self>, <domain>, <connection (integer)>.
     */
    int iterate_connections(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_domain_iterate_connections(self,
					domain_iterate_connections_handler,
					handler_val);
	return 0;
    }

    /*
     * Attempt to activate the given connection.
     */
    int activate_connection(int connection)
    {
	return ipmi_domain_activate_connection(self, connection);
    }

    /*
     * Parm 1 is a connection number.  Sets the second parameter to
     * true if the connection is active, false if not.  Returns an
     * error value.
     */
    int is_connection_active(int connection, unsigned int *active)
    {
	return ipmi_domain_is_connection_active(self, connection, active);
    }

    /*
     * Parm 1 is a connection number.  Sets the second parameter to true
     * if the connection is up, false if not.  Returns an error value.
     */
    int is_connection_up(int connection, unsigned int *up)
    {
	return ipmi_domain_is_connection_up(self, connection, up);
    }

    /*
     * Parm 1 is a connection number.  Sets the second parameter to
     * the number of ports in the connection.  A connection may have
     * multiple ports (ie, multiple IP addresses to the same BMC,
     * whereas a separate connection is a connection to a different
     * BMC); these functions let you check their status.  Returns an
     * error value.
     */
    int num_connection_ports(int connection, unsigned int *ports)
    {
	return ipmi_domain_num_connection_ports(self, connection, ports);
    }

    /*
     * Parm 1 is a connection number, parm 2 is a port number.  Sets
     * parm 3 to true if the given port is up, false if not.  Returns
     * an error value.
     */
    int is_connection_port_up(int          connection,
			      int          port,
			      unsigned int *up)
    {
	return ipmi_domain_is_connection_port_up(self, connection, port, up);
    }

    /*
     * Add a handler to be called when an entity is added, updated, or
     * removed. When the entity is updated the entity_updated_cb
     * method on the first parameter will be called with the following
     * parameters: <self>, added|deleted|changed <domain>, <entity>.
     */
    int add_entity_update_handler(swig_cb handler)
    {
	cb_add(domain, entity_update);
    }

    /*
     * Remove the connection change handler.
     */
    int remove_entity_update_handler(swig_cb handler)
    {
	cb_rm(domain, entity_update);
    }

    /*
     * Iterate through all the entities in the object.  The
     * domain_iter_entities_cb method will be called on the first
     * parameter for each entity in the domain.  The parameters it
     * receives will be: <self>, <domain>, <entity>.
     */
    int iterate_entities(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_domain_iterate_entities(self, domain_iterate_entities_handler,
				     handler_val);
	return 0;
    }

    /*
     * Add a handler to be called when an MC is added, updated, or
     * removed. When the mc is updated the mc_update_cb method on the
     * first parameter will be called with the following parameters:
     * <self>, added|deleted|changed <domain>, <mc>.
     */
    int add_mc_update_handler(swig_cb handler)
    {
	cb_add(domain, mc_updated);
    }

    /*
     * Remove the connection change handler.
     */
    int remove_mc_update_handler(swig_cb handler)
    {
	cb_rm(domain, mc_updated);
    }

    /*
     * Iterate through all the MCs in the object.  The
     * mc_iter_cb method will be called on the first parameter for
     * each mc in the domain.  The parameters it receives will be:
     * <self>, <domain> <mc>.
     */
    int iterate_mcs(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_domain_iterate_mcs(self, domain_iterate_mcs_handler, handler_val);
	return 0;
    }

    /*
     * Return the type of the domain, either unknown, mxp, or atca.
     * Others may be added later.
     */
    char *get_type()
    {
	return ipmi_domain_get_type_string(ipmi_domain_get_type(self));
    }

    /*
     * Scan all the addresses on the given channel (parm 1) between
     * (and including) start_addr (parm 2) and end_addr (parm 3) and
     * call the "ipmb_mc_scan_cb" method on the handler (parm4) with
     * the following parms:
     * <self>, <domain>, <error val>
     */
    int start_ipmb_mc_scan(int channel, int start_addr, int end_addr,
			   swig_cb handler = NULL)
    {
	int            rv;
	swig_cb_val    handler_val = NULL;
	ipmi_domain_cb domain_cb = NULL;

	if (valid_swig_cb(handler)) {
	    domain_cb = ipmb_mc_scan_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_start_ipmb_mc_scan(self, channel, start_addr, end_addr,
				     domain_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Send a command to a given address (parm 1) with the given lun
     * (parm 2), netfn (parm 3), command (parm 4).  Parm 5 is the
     * message data in an array reference.  Parm 6 is the handler, it
     * will be called with the response.  The addr_cmd_cb method will
     * be called on the handler handler; its parameters are:
     * <domain> <addr> <lun> <netfn> <cmd> <response data>
     */
    int send_command_addr(char *addr, int lun, int netfn, int cmd,
			  intarray msg_data, swig_cb handler = NULL)
    {
	int                          rv;
	swig_cb_val                  handler_val = NULL;
	ipmi_addr_response_handler_t msg_cb = NULL;
	ipmi_addr_t                  iaddr;
	unsigned int                 addr_len;
	ipmi_msg_t                   msg;
	unsigned char                data[MAX_IPMI_DATA_SIZE];
	unsigned int                 data_len;

	rv = parse_ipmi_addr(addr, lun, &iaddr, &addr_len);
	if (rv)
	    return rv;

	msg.netfn = netfn;
	msg.cmd = cmd;
	msg.data = data;
	rv = parse_ipmi_data(msg_data, data, sizeof(data), &data_len);
	msg.data_len = data_len;
	if (rv)
	    return rv;

	if (valid_swig_cb(handler)) {
	    msg_cb = domain_msg_cb;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_send_command_addr(self, &iaddr, addr_len, &msg,
				    msg_cb, handler_val, NULL);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Cause the domain to start detecting presence changes.  If parm
     * 1 is supplied, it tells whether to force all entities to have
     * their presence checked (if true) or just detect entity presence
     * for ones that might have changed.
     */
    int detect_presence_changes(int force = 0)
    {
	return ipmi_detect_domain_presence_changes(self, force);
    }

    /*
     * Set the time (in seconds) between SEL rescans for all
     * SELs in the domain
     */
    void set_sel_rescan_time(int seconds)
    {
	return ipmi_domain_set_sel_rescan_time(self, seconds);
    }

    /*
     * Get the default SEL rescan time for the domain.
     */
    int get_sel_rescan_time()
    {
	return ipmi_domain_get_sel_rescan_time(self);
    }

    /*
     * Set the time (in seconds) between IPMB bus rescans for the
     * domain.
     */
    void set_ipmb_rescan_time(int seconds)
    {
	return ipmi_domain_set_ipmb_rescan_time(self, seconds);
    }

    /*
     * Get the default IPMB rescan time for the domain.
     */
    int get_ipmb_rescan_time()
    {
	return ipmi_domain_get_ipmb_rescan_time(self);
    }

    /*
     * Add a handler to be called when a new unhandled event comes
     * into the domain.  When the event comes in, the event_cb method
     * on the first parameter will be called with the following
     * parameters: <self>, <domain>, <event>
     */
    int add_event_handler(swig_cb handler)
    {
	cb_add(domain, event);
    }

    /*
     * Remove the event handler.
     */
    int remove_event_handler(swig_cb handler)
    {
	cb_rm(domain, event);
    }

    %newobject ipmi_domain_first_event;
    /*
     * Retrieve the first event from the domain.  Return NULL (undef)
     * if the event does not exist.
     */
    ipmi_event_t *ipmi_domain_first_event()
    {
	return ipmi_domain_first_event(self);
    }

    %newobject ipmi_domain_last_event;
    /*
     * Retrieve the last event from the domain.
     */
    ipmi_event_t *ipmi_domain_last_event()
    {
	return ipmi_domain_last_event(self);
    }

    %newobject ipmi_domain_next_event;
    /*
     * Retrieve the event after the given event from the domain.
     */
    ipmi_event_t *ipmi_domain_next_event(ipmi_event_t  *event)
    {
	return ipmi_domain_next_event(self, event);
    }

    %newobject ipmi_domain_prev_event;;
    /*
     * Retrieve the event before the given event from the domain.
     */
    ipmi_event_t *ipmi_domain_prev_event(ipmi_event_t  *event)
    {
	return ipmi_domain_prev_event(self, event);
    }

    /*
     * Number of live entries in the local SEL copy.
     */
    int sel_count()
    {
	int          rv;
	unsigned int count;
	rv = ipmi_domain_sel_count(self, &count);
	if (rv)
	    return 0;
	else
	    return count;
    }

    /*
     * Number of entries in the the remote SEL.  If an entry has been
     * deleted in the local copy of the SEL but has not yet finished
     * being deleted in the remote copy, it will be counted here.
     */
    int sel_entries_used()
    {
	int          rv;
	unsigned int count;
	rv = ipmi_domain_sel_entries_used(self, &count);
	if (rv)
	    return 0;
	else
	    return count;
    }

    /*
     * Reread all SELs in the domain.  The callback (if supplied) will
     * be called with the following values:
     * <domain> <error value>
     */
    int domain_reread_sels(swig_cb handler = NULL)
    {
	int            rv;
	swig_cb_val    handler_val = NULL;
	ipmi_domain_cb domain_cb = NULL;

	if (valid_swig_cb(handler)) {
	    domain_cb = domain_reread_sels_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_domain_reread_sels(self, domain_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }
}

/*
 * A entity id object.  This object is guaranteed to be valid and
 * can be converted into a entity pointer later.
 */
%extend ipmi_entity_id_t {
    ~ipmi_entity_id_t()
    {
	free(self);
    }

    /*
     * Convert a entity id to a entity pointer.  The "entity_cb" method
     * will be called on the first parameter with the following parameters:
     * <self> <entity>
     */
    char *convert_to_entity(swig_cb handler)
    {
	int rv;

	if (! valid_swig_cb(handler))
	    return NULL;

	rv = ipmi_entity_pointer_cb(*self, handle_entity_cb,
				    get_swig_cb(handler));
	if (rv)
	    return strerror(rv);
	return NULL;
    }
}

/*
 * And entity object.
 */
%extend ipmi_entity_t {
    %newobject get_name;
    /*
     * Get the name of an entity.
     */
    char *get_name()
    {
	char name[IPMI_ENTITY_NAME_LEN];

	ipmi_entity_get_name(self, name, sizeof(name));
	return strdup(name);
    }

    %newobject get_id;
    /*
     * Get the id for the entity.
     */
    ipmi_entity_id_t *get_id()
    {
	ipmi_entity_id_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_entity_convert_to_id(self);
	return rv;
    }

    /*
     * Iterate through all the entity's children.  The
     * entity_iter_entities_cb method will be called on the first
     * parameter for each child entity of the parent.  The parameters
     * it receives will be: <self> <parent> <child>.
     */
    int iterate_children(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_entity_iterate_children(self, entity_iterate_entities_handler,
				     handler_val);
	return 0;
    }

    /*
     * Iterate through all the entity's parents.  The
     * entity_iter_entities_cb method will be called on the first
     * parameter for each parent entity of the child.  The parameters
     * it receives will be: <self> <child> <parent>.
     */
    int iterate_parents(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_entity_iterate_parents(self, entity_iterate_entities_handler,
				    handler_val);
	return 0;
    }

    /*
     * Iterate through all the entity's sensors.  The
     * entity_iter_sensors_cb method will be called on the first
     * parameter for each sensor of the entity.  The parameters
     * it receives will be: <self> <entity> <sensor>.
     */
    int iterate_sensors(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_entity_iterate_sensors(self, entity_iterate_sensors_handler,
				    handler_val);
	return 0;
    }

    /*
     * Iterate through all the entity's controls.  The
     * entity_iter_controls_cb method will be called on the first
     * parameter for each control of the entity.  The parameters
     * it receives will be: <self> <entity> <control>.
     */
    int iterate_controls(swig_cb handler)
    {
	swig_cb_val handler_val;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = get_swig_cb(handler);
	ipmi_entity_iterate_controls(self, entity_iterate_controls_handler,
				     handler_val);
	return 0;
    }

    /*
     * Add a handler to be called when an entity's presence
     * changes. When the presence changes the entity_presence_cb
     * method on the first parameter will be called with the following
     * parameters: <self> <entity> <present (boolean integer)> <event>.
     * The event is optional and may not be present.
     */
    int add_presence_handler(swig_cb handler)
    {
	cb_add(entity, presence);
    }

    /*
     * Remove the presence handler.
     */
    int remove_presence_handler(swig_cb handler)
    {
	cb_rm(entity, presence);
    }

    /*
     * Add a handler to be called when a sensor in the entity is added,
     * deleted, or updated.  When the sensor changes the entity_sensor_cb
     * method on the first parameter will be called with the following
     * parameters: <self> added|deleted|changed <entity> <sensor>.
     */
    int add_sensor_update_handler(swig_cb handler)
    {
	cb_add(entity, sensor_update);
    }

    /*
     * Remove the sensor update handler.
     */
    int remove_sensor_update_handler(swig_cb handler)
    {
	cb_rm(entity, sensor_update);
    }

    /*
     * Add a handler to be called when a control in the entity is added,
     * deleted, or updated.  When the control changes the entity_control_cb
     * method on the first parameter will be called with the following
     * parameters: <self> added|deleted|changed <entity> <control>.
     */
    int add_control_update_handler(swig_cb handler)
    {
	cb_add(entity, control_update);
    }

    /*
     * Remove the control update handler.
     */
    int remove_control_update_handler(swig_cb handler)
    {
	cb_rm(entity, control_update);
    }

    /*
     * Add a handler to be called when the FRU data in the entity is added,
     * deleted, or updated.  When the FRU data changes the entity_fru_cb
     * method on the first parameter will be called with the following
     * parameters: <self> added|deleted|changed <entity> <fru>.
     */
    int add_fru_update_handler(swig_cb handler)
    {
	cb_add(entity, fru_update);
    }

    /*
     * Remove the FRU data update handler.
     */
    int remove_fru_update_handler(swig_cb handler)
    {
	cb_rm(entity, fru_update);
    }

    /*
     * Get the entities type, return "mc", "fru", "generic", or "unknown".
     */
    char *get_type()
    {
	switch (ipmi_entity_get_type(self)) {
	case IPMI_ENTITY_MC: return "mc";
	case IPMI_ENTITY_FRU: return "fru";
	case IPMI_ENTITY_GENERIC: return "generic";
	default: return "unknown";
	}
    }

    /*
     * Returns if the entity has FRU data or not.
     */
    int is_fru()
    {
	return ipmi_entity_get_is_fru(self);
    }

    /*
     * Returns the domain for the entity.
     */
    ipmi_domain_t *get_domain()
    {
	return ipmi_entity_get_domain(self);
    }

#define ENTITY_ID_UNSPECIFIED	       			0
#define ENTITY_ID_OTHER					1
#define ENTITY_ID_UNKOWN				2
#define ENTITY_ID_PROCESSOR				3
#define ENTITY_ID_DISK					4
#define ENTITY_ID_PERIPHERAL				5
#define ENTITY_ID_SYSTEM_MANAGEMENT_MODULE		6
#define ENTITY_ID_SYSTEM_BOARD				7
#define ENTITY_ID_MEMORY_MODULE				8
#define ENTITY_ID_PROCESSOR_MODULE			9
#define ENTITY_ID_POWER_SUPPLY				10
#define ENTITY_ID_ADD_IN_CARD				11
#define ENTITY_ID_FRONT_PANEL_BOARD			12
#define ENTITY_ID_BACK_PANEL_BOARD			13
#define ENTITY_ID_POWER_SYSTEM_BOARD			14
#define ENTITY_ID_DRIVE_BACKPLANE			15
#define ENTITY_ID_SYSTEM_INTERNAL_EXPANSION_BOARD	16
#define ENTITY_ID_OTHER_SYSTEM_BOARD			17
#define ENTITY_ID_PROCESSOR_BOARD			18
#define ENTITY_ID_POWER_UNIT				19
#define ENTITY_ID_POWER_MODULE				20
#define ENTITY_ID_POWER_MANAGEMENT_BOARD		21
#define ENTITY_ID_CHASSIS_BACK_PANEL_BOARD		22
#define ENTITY_ID_SYSTEM_CHASSIS			23
#define ENTITY_ID_SUB_CHASSIS				24
#define ENTITY_ID_OTHER_CHASSIS_BOARD			25
#define ENTITY_ID_DISK_DRIVE_BAY			26
#define ENTITY_ID_PERIPHERAL_BAY			27
#define ENTITY_ID_DEVICE_BAY				28
#define ENTITY_ID_FAN_COOLING				29
#define ENTITY_ID_COOLING_UNIT				30
#define ENTITY_ID_CABLE_INTERCONNECT			31
#define ENTITY_ID_MEMORY_DEVICE				32
#define ENTITY_ID_SYSTEM_MANAGEMENT_SOFTWARE		33
#define ENTITY_ID_BIOS					34
#define ENTITY_ID_OPERATING_SYSTEM			35
#define ENTITY_ID_SYSTEM_BUS				36
#define ENTITY_ID_GROUP					37
#define ENTITY_ID_REMOTE_MGMT_COMM_DEVICE		38
#define ENTITY_ID_EXTERNAL_ENVIRONMENT			39
#define ENTITY_ID_BATTERY				40
#define ENTITY_ID_PROCESSING_BLADE			41
#define ENTITY_ID_CONNECTIVITY_SWITCH			42
#define ENTITY_ID_PROCESSOR_MEMORY_MODULE		43
#define ENTITY_ID_IO_MODULE				44
#define ENTITY_ID_PROCESSOR_IO_MODULE			45
#define ENTITY_ID_MGMT_CONTROLLER_FIRMWARE		46
#define ENTITY_ID_IPMI_CHANNEL				47
#define ENTITY_ID_PCI_BUS				48
#define ENTITY_ID_PCI_EXPRESS_BUS			49
#define ENTITY_ID_SCSI_BUS				50
#define ENTITY_ID_SATA_SAS_BUS				51
#define ENTITY_ID_PROCESSOR_FRONT_SIDE_BUS		52

    /*
     * Get the entity id for the entity
     */
    int get_entity_id()
    {
	return ipmi_entity_get_entity_id(self);
    }

    /*
     * Get the entity instance for the entity
     */
    int get_entity_instance()
    {
	return ipmi_entity_get_entity_instance(self);
    }

    /*
     * Get the channel for the entity.  Only valid if the entity
     * instance is 0x60 or larger.
     */
    int get_entity_device_channel()
    {
	return ipmi_entity_get_device_channel(self);
    }

    /*
     * Get the address for the entity.  Only valid if the entity
     * instance is 0x60 or larger.
     */
    int get_entity_device_address()
    {
	return ipmi_entity_get_device_address(self);
    }

    /*
     * Get the FRU data for the entity.  Note that you cannot hold the
     * FRU data pointer outside the context of where the entity pointer
     * is valid.
     */
    ipmi_fru_t *get_fru()
    {
	return ipmi_entity_get_fru(self);
    }

    /*
     * If this returns true, then the presence sensor is always there
     * for this entity.
     */
    int get_presence_sensor_always_there()
    {
	return ipmi_entity_get_presence_sensor_always_there(self);
    }

    /*
     * Returns if the entity has a parent.
     */
    int is_child()
    {
	return ipmi_entity_get_is_child(self);
    }

    /*
     * Returns if the entity has a child.
     */
    int is_parent()
    {
	return ipmi_entity_get_is_parent(self);
    }

    /*
     * Return the channel from the device locator record.  Valid for
     * all entities except unknown.
     */
    int get_channel()
    {
	return ipmi_entity_get_channel(self);
    }

    /*
     * Return the LUN from the device locator record.  Valid for
     * all entities except unknown.
     */
    int get_lun()
    {
	return ipmi_entity_get_lun(self);
    }

    /*
     * Return the OEM byte from the device locator record.  Valid for
     * all entities except unknown.
     */
    int get_oem()
    {
	return ipmi_entity_get_oem(self);
    }

    /*
     * Return the access address from the device locator record.  Valid for
     * FRU and generic entities.
     */
    int get_access_address()
    {
	return ipmi_entity_get_access_address(self);
    }

    /*
     * Return the private bus id from the device locator record.  Valid for
     * FRU and generic entities.
     */
    int get_private_bus_id()
    {
	return ipmi_entity_get_private_bus_id(self);
    }

    /*
     * Return the device type from the device locator record.  Valid for
     * FRU and generic entities.
     */
    int get_device_type()
    {
	return ipmi_entity_get_device_type(self);
    }

    /*
     * Return the device modifier from the device locator record.
     * Valid for FRU and generic entities.
     */
    int get_device_modifier()
    {
	return ipmi_entity_get_device_modifier(self);
    }

    /*
     * Return the slave address from the device locator record.  Valid for
     * MC and generic entities.
     */
    int get_slave_address()
    {
	return ipmi_entity_get_slave_address(self);
    }


    /*
     * Return if the FRU is logical (from the device locator record).
     * Valid for FRU entities.
     */
    int get_is_logical_fru()
    {
	return ipmi_entity_get_is_logical_fru(self);
    }

    /*
     * Return the device id from the device locator record.  Valid for
     * FRU entities.
     */
    int get_fru_device_id()
    {
	return ipmi_entity_get_fru_device_id(self);
    }

    /*
     * Return the ACPI system power notify required bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_ACPI_system_power_notify_required()
    {
	return ipmi_entity_get_ACPI_system_power_notify_required(self);
    }

    /*
     * Return the ACPI device power notify required bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_ACPI_device_power_notify_required()
    {
	return ipmi_entity_get_ACPI_device_power_notify_required(self);
    }

    /*
     * Return the controller logs init agent errors bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_controller_logs_init_agent_errors()
    {
	return ipmi_entity_get_controller_logs_init_agent_errors(self);
    }

    /*
     * Return the log init agent errors accessing bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_log_init_agent_errors_accessing()
    {
	return ipmi_entity_get_log_init_agent_errors_accessing(self);
    }

    /*
     * Return the global init bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_global_init()
    {
	return ipmi_entity_get_global_init(self);
    }

    /*
     * Return the chassis device bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_chassis_device()
    {
	return ipmi_entity_get_chassis_device(self);
    }

    /*
     * Return the !bridge bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_bridge()
    {
	return ipmi_entity_get_bridge(self);
    }

    /*
     * Return the IPMB event generator bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_IPMB_event_generator()
    {
	return ipmi_entity_get_IPMB_event_generator(self);
    }

    /*
     * Return the IPMB event receiver bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_IPMB_event_receiver()
    {
	return ipmi_entity_get_IPMB_event_receiver(self);
    }

    /*
     * Return the FRU inventory device bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_FRU_inventory_device()
    {
	return ipmi_entity_get_FRU_inventory_device(self);
    }

    /*
     * Return the SEL device bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_SEL_device()
    {
	return ipmi_entity_get_SEL_device(self);
    }

    /*
     * Return the SDR repository device bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_SDR_repository_device()
    {
	return ipmi_entity_get_SDR_repository_device(self);
    }

    /*
     * Return the sensor device bit from the
     * device locator record.  Valid for MC entities.
     */
    int get_sensor_device()
    {
	return ipmi_entity_get_sensor_device(self);
    }

    /*
     * Return the address span from the device locator record.  Valid
     * for generic entities.
     */
    int get_address_span()
    {
	return ipmi_entity_get_address_span(self);
    }

    %newobject get_dlr_id;
    /*
     * Return the id string from the DLR.
     */
    char *get_dlr_id()
    {
	/* FIXME - no unicode handling. */
	int len = ipmi_entity_get_id_length(self) + 1;
	char *id = malloc(len);
	ipmi_entity_get_id(self, id, len);
	return id;
    }

    /*
     * Returns true if the entity is present, false if not.
     */
    int is_present()
    {
	return ipmi_entity_is_present(self);
    }

    /*
     * Returns true if the entity is hot-swappable, false if not.
     */
    int is_hot_swappable()
    {
	return ipmi_entity_hot_swappable(self);
    }

    /*
     * Add a handler to be called when the hot-swap state for the
     * entity changes.  When the hot-swap state changes the
     * entity_hot_swap_update_cb method on the first parameter will be
     * called with the following parameters: <self> <entity> <old
     * state> <new state> <event>.  The event is optional and may not
     * be present.
     */
    int add_hot_swap_handler(swig_cb handler)
    {
	cb_add(entity, hot_swap);
    }

    /*
     * Remove the hot-swap update handler.
     */
    int remove_hot_swap_handler(swig_cb handler)
    {
	cb_rm(entity, hot_swap);
    }

    /*
     * Get the current hot-swap state for the entity.  The
     * entity_hot_swap_cb handler will be called with the following
     * parameters: <self> <entity> <err> <state>
     */
    int get_hot_swap_state(swig_cb handler)
    {
	swig_cb_val handler_val;
	int         rv;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = ref_swig_cb(handler);
	rv = ipmi_entity_get_hot_swap_state(self,
					    entity_get_hot_swap_handler,
					    handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Get the current hot-swap activation time for the entity.  The
     * entity_hot_swap_time_cb handler will be called with the
     * following parameters: <self> <entity> <err> <time>
     */
    int get_auto_activate_time(swig_cb handler)
    {
	swig_cb_val handler_val;
	int         rv;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = ref_swig_cb(handler);
	rv = ipmi_entity_get_auto_activate_time
	    (self,
	     entity_get_hot_swap_time_handler,
	     handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Set the current hot-swap activation time for the entity.  The
     * entity_hot_swap_time_cb handler will be called with the
     * following parameters: <self> <entity> <err>
     */
    int set_auto_activate_time(ipmi_timeout_t auto_act,
			       swig_cb        handler = NULL)
    {
	swig_cb_val    handler_val = NULL;
	ipmi_entity_cb done = NULL;
	int            rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = entity_set_hot_swap_time_handler;
	}
	rv = ipmi_entity_set_auto_activate_time
	    (self, auto_act, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Get the current hot-swap deactivation time for the entity.  The
     * entity_hot_swap_time_cb handler will be called with the
     * following parameters: <self> <entity> <err> <time>
     */
    int get_auto_deactivate_time(swig_cb handler)
    {
	swig_cb_val handler_val;
	int         rv;

	if (! valid_swig_cb(handler))
	    return EINVAL;

	handler_val = ref_swig_cb(handler);
	rv = ipmi_entity_get_auto_deactivate_time
	    (self,
	     entity_get_hot_swap_time_handler,
	     handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Set the current hot-swap deactivation time for the entity.  The
     * entity_hot_swap_time_cb handler will be called with the
     * following parameters: <self> <entity> <err>
     */
    int set_auto_deactivate_time(ipmi_timeout_t auto_act,
				 swig_cb        handler = NULL)
    {
	swig_cb_val    handler_val = NULL;
	ipmi_entity_cb done = NULL;
	int            rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = entity_set_hot_swap_time_handler;
	}
	rv = ipmi_entity_set_auto_deactivate_time
	    (self, auto_act, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Cause the entity to move from INACTIVE to ACTIVATION_REQUESTED
     * state, if possible. If the entity does not support this
     * operation, this will return ENOSYS and you can move straight
     * from INACTIVE to ACTIVE state by calling ipmi_entity_activate.
     * After this is done, the entity_activate_cb handler will be
     * called with the following parameters: <self> <entity> <err>
     */
    int set_activation_requested(swig_cb handler = NULL)
    {
	swig_cb_val    handler_val = NULL;
	ipmi_entity_cb done = NULL;
	int            rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = entity_activate_handler;
	}
	rv = ipmi_entity_set_activation_requested(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Attempt to activate an entity.  Activate will cause a
     * transition from INACTIVE to ACTIVE (but only if
     * ipmi_entity_set_activation_requested() returns ENOSYS), or from
     * ACTIVATION_REQUESTED to ACTIVE.  After this is done, the
     * entity_activate_cb handler will be called with the following
     * parameters: <self> <entity> <err>
     */
    int activate(swig_cb handler = NULL)
    {
	swig_cb_val    handler_val = NULL;
	ipmi_entity_cb done = NULL;
	int            rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = entity_activate_handler;
	}
	rv = ipmi_entity_activate(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Attempt to deactivate an entity.  Deactivate will cause a
     * transition from DEACTIVATION_REQUESTED or ACTIVE to INACTIVE.
     * After this is done, the entity_activate_cb handler will be
     * called with the following parameters: <self> <entity> <err>
     */
    int deactivate(swig_cb handler = NULL)
    {
	swig_cb_val    handler_val = NULL;
	ipmi_entity_cb done = NULL;
	int         rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = entity_activate_handler;
	}
	rv = ipmi_entity_deactivate(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Check the state of hot-swap for the entity.  This causes the
     * local state to be audited against the actual state.
     */
    int check_hot_swap_state()
    {
	return ipmi_entity_check_hot_swap_state(self);
    }

}

/*
 * A mc id object.  This object is guaranteed to be valid and
 * can be converted into a mc pointer later.
 */
%extend ipmi_mcid_t {
    ~ipmi_mcid_t()
    {
	free(self);
    }

    /*
     * Convert a mc id to a mc pointer.  The "mc_cb" method
     * will be called on the first parameter with the following parameters:
     * <self> <mc>
     */
    char *convert_to_mc(swig_cb handler)
    {
	int rv;

	if (! valid_swig_cb(handler))
	    return NULL;

	rv = ipmi_mc_pointer_cb(*self, handle_mc_cb,
				get_swig_cb(handler));
	if (rv)
	    return strerror(rv);
	return NULL;
    }
}

/*
 * An MC object
 */
%extend ipmi_mc_t {
    %newobject get_name;
    /*
     * Get the name of an mc.
     */
    char *get_name()
    {
	char name[IPMI_MC_NAME_LEN];

	ipmi_mc_get_name(self, name, sizeof(name));
	return strdup(name);
    }

    %newobject get_id;
    /*
     * Get the id for the mc.
     */
    ipmi_mcid_t *get_id()
    {
	ipmi_mcid_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_mc_convert_to_id(self);
	return rv;
    }

    /*
     * Return the domain the MC is in.
     */
    ipmi_domain_t *get_domain()
    {
	return ipmi_mc_get_domain(self);
    }

    /*
     * Get the provides_device_sdrs from the get device id response
     * from the MC.
     */
    int provides_device_sdrs()
    {
	return ipmi_mc_provides_device_sdrs(self);
    }

    /*
     * Get the device_available bit from the get device id response
     * from the MC.
     */
    int device_available()
    {
	return ipmi_mc_device_available(self);
    }

    /*
     * Get the chassis_support bit from the get device id response
     * from the MC.
     */
    int chassis_support()
    {
	return ipmi_mc_chassis_support(self);
    }

    /*
     * Get the bridge_support bit from the get device id response
     * from the MC.
     */
    int bridge_support()
    {
	return ipmi_mc_bridge_support(self);
    }

    /*
     * Get the ipmb_event_generator_support bit from the get device id response
     * from the MC.
     */
    int ipmb_event_generator_support()
    {
	return ipmi_mc_ipmb_event_generator_support(self);
    }

    /*
     * Get the ipmb_event_receiver_support bit from the get device id response
     * from the MC.
     */
    int ipmb_event_receiver_support()
    {
	return ipmi_mc_ipmb_event_receiver_support(self);
    }

    /*
     * Get the fru_inventory_support bit from the get device id response
     * from the MC.
     */
    int fru_inventory_support()
    {
	return ipmi_mc_fru_inventory_support(self);
    }

    /*
     * Get the sel_device_support bit from the get device id response
     * from the MC.
     */
    int sel_device_support()
    {
	return ipmi_mc_sel_device_support(self);
    }

    /*
     * Get the sdr_repository_support bit from the get device id response
     * from the MC.
     */
    int sdr_repository_support()
    {
	return ipmi_mc_sdr_repository_support(self);
    }

    /*
     * Get the sensor_device_support bit from the get device id response
     * from the MC.
     */
    int sensor_device_support()
    {
	return ipmi_mc_sensor_device_support(self);
    }

    /*
     * Get the device_id from the get device id response
     * from the MC.
     */
    int device_id()
    {
	return ipmi_mc_device_id(self);
    }

    /*
     * Get the device_revision from the get device id response
     * from the MC.
     */
    int device_revision()
    {
	return ipmi_mc_device_revision(self);
    }

    /*
     * Get the major_fw_revision from the get device id response
     * from the MC.
     */
    int major_fw_revision()
    {
	return ipmi_mc_major_fw_revision(self);
    }

    /*
     * Get the minor_fw_revision from the get device id response
     * from the MC.
     */
    int minor_fw_revision()
    {
	return ipmi_mc_minor_fw_revision(self);
    }

    /*
     * Get the major_version from the get device id response
     * from the MC.
     */
    int major_version()
    {
	return ipmi_mc_major_version(self);
    }

    /*
     * Get the minor_version from the get device id response
     * from the MC.
     */
    int minor_version()
    {
	return ipmi_mc_minor_version(self);
    }

    /*
     * Get the manufacturer_id from the get device id response
     * from the MC.
     */
    int manufacturer_id()
    {
	return ipmi_mc_manufacturer_id(self);
    }

    /*
     * Get the product_id from the get device id response
     * from the MC.
     */
    int product_id()
    {
	return ipmi_mc_product_id(self);
    }

    /*
     * Get the auxiliary firmware revision.  This returns a string
     * with four bytes set.
     */
    %newobject aux_fw_revision;
    char *aux_fw_revision()
    {
	char *str;
	unsigned char data[4];

	str = malloc(28);
	ipmi_mc_aux_fw_revision(self, data);
	snprintf(str, 28,
		 "0x%2.2x 0x%2.2x 0x%2.2x 0x%2.2x",
		 data[0], data[1], data[2], data[3]);
	return str;
    }

    /*
     * Check to see if the MC is operational in the system.  If this
     * is return sfalse, then the MC was referred to by an SDR, but it
     * doesn't really exist (at least not yet).
     */
    int is_active()
    {
	return ipmi_mc_is_active(self);
    }

    /*
     * Add a handler to be called when an mc's active state
     * changes. When the active state changes the mc_active_cb
     * method on the first parameter will be called with the following
     * parameters: <self> <mc> <active (boolean integer)>.
     */
    int add_active_handler(swig_cb handler)
    {
	cb_add(mc, active);
    }

    /*
     * Remove the presence handler.
     */
    int remove_active_handler(swig_cb handler)
    {
	cb_rm(mc, active);
    }

    /*
     * Send a command to a given MC with the given lun
     * (parm 1), netfn (parm 2), command (parm 3).  Parm 4 is the
     * message data in an array reference.  Parm 5 is the handler, it
     * will be called with the response.  The mc_cmd_cb method will
     * be called on the handler handler; its parameters are:
     * <mc> <netfn> <cmd> <response data>
     */
    int ipmi_mc_send_command(int       lun,
			     int       netfn,
			     int       cmd,
			     intarray  msg_data,
			     swig_cb   handler = NULL)
    {
	int                        rv;
	swig_cb_val                handler_val = NULL;
	ipmi_mc_response_handler_t msg_cb = NULL;
	ipmi_msg_t                 msg;
	unsigned char              data[MAX_IPMI_DATA_SIZE];
	unsigned int               data_len;

	msg.netfn = netfn;
	msg.cmd = cmd;
	msg.data = data;
	rv = parse_ipmi_data(msg_data, data, sizeof(data), &data_len);
	msg.data_len = data_len;
	if (rv)
	    return rv;

	if (valid_swig_cb(handler)) {
	    msg_cb = mc_msg_cb;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_mc_send_command(self, lun, &msg, msg_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

#define IPMI_MC_RESET_COLD 1
#define IPMI_MC_RESET_WARM 2
    /*
     * Reset the MC, either a cold or warm reset depending on the
     * first parm.  Note that the effects of a reset are not defined
     * by IPMI, so this might do wierd things.  Some systems do not
     * support resetting the MC.  This is not a standard control
     * because there is no entity to hang if from and you don't want
     * people messing with it unless they really know what they are
     * doing.  When the reset is complete the mc_reset_cb will
     * be called on the second parameter of this call with the
     * following parameters: <self> <mc> <err>
     */
    int reset(int     reset_type,
	      swig_cb handler = NULL)
    {
	swig_cb_val     handler_val = NULL;
	ipmi_mc_done_cb done = NULL;
	int             rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = mc_reset_handler;
	}
	rv = ipmi_mc_reset(self, reset_type, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /* Get the setting to enable events for the entire MC.  The value
       returned by the get function is a boolean telling whether
       events are enabled. */
    int get_events_enable()
    {
	return ipmi_mc_get_events_enable(self);
    }

    /*
     * Set the setting to enable events for the entire MC.  The "val"
     * passed in as the first parameter is a boolean telling whether
     * to turn events on (true) or off (false).  When the operation
     * completes the mc_events_enable_cb will be called on the handler
     * with the following parameters: <self> <mc> <err>.
     */
    int set_events_enable(int     val,
			  swig_cb handler = NULL)
    {
	swig_cb_val     handler_val = NULL;
	ipmi_mc_done_cb done = NULL;
	int             rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = mc_events_enable_handler;
	}
	rv = ipmi_mc_set_events_enable(self, val, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }


    /*
     * Reread all the sensors for a given mc.  This will request the
     * device SDRs for that mc (And only for that MC) and change the
     * sensors as necessary. */
    int reread_sensors(swig_cb handler = NULL)
    {
	swig_cb_val     handler_val = NULL;
	ipmi_mc_done_cb done = NULL;
	int             rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = mc_reread_sensors_handler;
	}
	rv = ipmi_mc_reread_sensors(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Set the time between SEL rescans for the MC (and only that MC).
     * Parm 1 is the time in seconds.
     */
    void ipmi_mc_set_sel_rescan_time(unsigned int seconds)
    {
	ipmi_mc_set_sel_rescan_time(self, seconds);
    }

    /*
     * Return the current SEL rescan time for the MC.
     */
    int get_sel_rescan_time()
    {
	return ipmi_mc_get_sel_rescan_time(self);
    }

    /* Reread the sel for the MC.  When the hander is called, all the
     * events in the SEL have been fetched into the local copy of the SEL
     * (with the obvious caveat that this is a distributed system and
     * other things may have come in after the read has finised).
     * When this completes, the mc_reread_sel_cb method will be called
     * on the handler (parm 1) with the parameters: <self> <mc> <err>. */
    int reread_sel(swig_cb handler = NULL)
    {
	swig_cb_val     handler_val = NULL;
	ipmi_mc_done_cb done = NULL;
	int             rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = mc_reread_sel_handler;
	}
	rv = ipmi_mc_reread_sel(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /* Fetch the current time from the SEL. */
    int get_current_sel_time(swig_cb handler)
    {
	swig_cb_val     handler_val = NULL;
	sel_get_time_cb done = NULL;
	int             rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = mc_sel_get_time_cb;
	}
	rv = ipmi_mc_get_current_sel_time(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    %newobject first_event;
    /*
     * Retrieve the first event from the MC.  Return NULL (undef)
     * if the event does not exist.
     */
    ipmi_event_t *first_event()
    {
	return ipmi_mc_first_event(self);
    }

    %newobject last_event;
    /*
     * Retrieve the last event from the MC.
     */
    ipmi_event_t *last_event()
    {
	return ipmi_mc_last_event(self);
    }

    %newobject next_event;
    /*
     * Retrieve the next event from the MC.
     */
    ipmi_event_t *next_event(ipmi_mc_t *mc, ipmi_event_t *event)
    {
	return ipmi_mc_next_event(self, event);
    }

    %newobject prev_event;
    /*
     * Retrieve the previous event from the MC.
     */
    ipmi_event_t *prev_event(ipmi_mc_t *mc, ipmi_event_t *event)
    {
	return ipmi_mc_prev_event(self, event);
    }

    %newobject event_by_recid;
    /*
     * Retrieve the event with the given record id from the MC.
     */
    ipmi_event_t *event_by_recid(ipmi_mc_t *mc,
				  int      record_id)
    {
	return ipmi_mc_event_by_recid(self, record_id);
    }

    /*
     * The number of live items in the local copy of the MC's SEL.
     */
    int sel_count()
    {
	return ipmi_mc_sel_count(self);
    }

    /*
     * Number of entries in the the remote SEL.  If an entry has been
     * deleted in the local copy of the SEL but has not yet finished
     * being deleted in the remote copy, it will be counted here.
     */
    int sel_entries_used()
    {
	return ipmi_mc_sel_entries_used(self);
    }

    /*
     * The major version of the MC's SEL.
     */
    int sel_get_major_version()
    {
	return ipmi_mc_sel_get_major_version(self);
    }

    /*
     * The minor version of the MC's SEL.
     */
    int sel_get_minor_version()
    {
	return ipmi_mc_sel_get_minor_version(self);
    }

    /*
     * The number of entries available in the MC's SEL.
     */
    int sel_get_num_entries()
    {
	return ipmi_mc_sel_get_num_entries(self);
    }

    /*
     * The number of free bytes available in the MC's SEL.
     */
    int sel_get_free_bytes()
    {
	return ipmi_mc_sel_get_free_bytes(self);
    }

    /*
     * Has an overflow occurred since the last SEL operation?
     */
    int sel_get_overflow()
    {
	return ipmi_mc_sel_get_overflow(self);
    }

    /*
     * Does the SEL support individual deletes of entries?
     */
    int sel_get_supports_delete_sel()
    {
	return ipmi_mc_sel_get_supports_delete_sel(self);
    }

    /*
     * Does the SEL support partial adds of entries?
     */
    int sel_get_supports_partial_add_sel()
    {
	return ipmi_mc_sel_get_supports_partial_add_sel(self);
    }

    /*
     * Does the SEL support the reserve protocol?
     */
    int sel_get_supports_reserve_sel()
    {
	return ipmi_mc_sel_get_supports_reserve_sel(self);
    }

    /*
     * Does the SEL support getting the SEL allocastion?
     */
    int sel_get_supports_get_sel_allocation()
    {
	return ipmi_mc_sel_get_supports_get_sel_allocation(self);
    }

    /*
     * The timestamp of the last time something was added to the SEL.
     */
    int sel_get_last_addition_timestamp()
    {
	return ipmi_mc_sel_get_last_addition_timestamp(self);
    }
}

/*
 * A sensor id object.  This object is guaranteed to be valid and
 * can be converted into a mc pointer later.
 */
%extend ipmi_sensor_id_t {
    ~ipmi_sensor_id_t()
    {
	free(self);
    }

    /*
     * Convert a sensor id to a sensor pointer.  The "sensor_cb" method
     * will be called on the first parameter with the following parameters:
     * <self> <sensor>
     */
    char *convert_to_sensor(swig_cb handler)
    {
	int rv;

	if (! valid_swig_cb(handler))
	    return NULL;

	rv = ipmi_sensor_pointer_cb(*self, handle_sensor_cb,
				    get_swig_cb(handler));
	if (rv)
	    return strerror(rv);
	return NULL;
    }
}

/*
 * An sensor object.  Sensor operations take several different types
 * of objects.  These are mostly strings that are a list of values.
 *
 * Event states are represented as a string with value separated by
 * spaces.  These value are settings and the events.  The strings
 * "events", "scanning", and "busy" are settings for the full sensor
 * event states.  For threshold sensor, the other values in the string
 * are 4 characters with: 1st character: u for upper or l for lower.
 * 2nd character: n for non-critical, c for critical, and r for
 * non-recoverable.  3rd character: h for going high and l for going
 * low.  4th character: a for assertion and d for deassertion.  For
 * discrete sensors, the other values are a 1 or 2-digit number
 * representing the offset and then a for assertion and d for
 * deassertion.
 *
 * A states structure is similar to event status, but does not have
 * the last two characters (direction and assertion) for thresholds
 * and last chararacter (assertion) for discrete values.
 */
%extend ipmi_sensor_t {
    %newobject get_name;
    /*
     * Get the name of an sensor.
     */
    char *get_name()
    {
	char name[IPMI_SENSOR_NAME_LEN];

	ipmi_sensor_get_name(self, name, sizeof(name));
	return strdup(name);
    }

    %newobject get_id;
    /*
     * Get the id for the sensor.
     */
    ipmi_sensor_id_t *get_id()
    {
	ipmi_sensor_id_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_sensor_convert_to_id(self);
	return rv;
    }

    /*
     * Register a handler to be called when an event comes from the
     * sensor.  If the sensor is a threshold sensor, the
     * threshold_event_cb method will be called on the sensor.
     * Otherwise, the sensor is discrete and the discrete_event_cb
     * will be called.  The threshold_event_cb method takes the
     * following parameters:
     * <self> <sensor> <event> <raw_set> <raw> <value_set> <value> <event>
     * The discrete_event_cb method takes the following parameters:
     * <self> <sensor> <event> <severity> <old_severity> <event>
     */
    int add_event_handler(swig_cb handler)
    {
	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    cb_add(sensor, threshold_event);
	} else {
	    cb_add(sensor, discrete_event);
	}
    }

    /*
     * Remove the event handler from the sensor
     */
    int remove_event_handler(swig_cb handler)
    {
	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    cb_rm(sensor, threshold_event);
	} else {
	    cb_rm(sensor, discrete_event);
	}
    }

    /* Set the event enables for the given sensor to exactly the event
     * states given in the first parameter.  This will first enable
     * the events/thresholds that are set, then disable the
     * events/thresholds that are not set.  When the operation is
     * done, the sensor_event_enable_cb method on the second parm will
     * be called with the following parameters: <self> <sensor> <err>
     */
    int set_event_enables(char *states, swig_cb handler = NULL)
    {
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;
	ipmi_event_state_t  *st;

	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    rv = str_to_threshold_event_state(states, &st);
	} else {
	    rv = str_to_discrete_event_state(states, &st);
	}
	if (rv)
	    return rv;
	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_event_enable_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_set_event_enables(self, st, sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	free(st);
	return rv;
    }

    /* Enable the event states that are set in the first parameter.  This
     * will *only* enable those states, it will not disable any
     * states.  It will, however, set the "events" flag and the
     * "scanning" flag for the sensor to the value in the states
     * parameter.  When the operation is done, the
     * sensor_event_enable_cb method on the second parm will be called
     * with the following parameters: <self> <sensor> <err>
     */
    int enable_events(char *states, swig_cb handler = NULL)
    {
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;
	ipmi_event_state_t  *st;

	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    rv = str_to_threshold_event_state(states, &st);
	} else {
	    rv = str_to_discrete_event_state(states, &st);
	}
	if (rv)
	    return rv;
	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_event_enable_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_enable_events(self, st, sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	free(st);
	return rv;
    }

    /* Disable the event states that are set in the first parameter.
     * This will *only* disable those states, it will not enable any
     * states.  It will, however, set the "events" flag and the
     * "scanning" flag for the sensor to the value in the states
     * parameter.  When the operation is done, the
     * sensor_event_enable_cb method on the second parm will be called
     * with the following parameters: <self> <sensor> <err>
     */
    int disable_events(char *states, swig_cb handler = NULL)
    {
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;
	ipmi_event_state_t  *st;

	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    rv = str_to_threshold_event_state(states, &st);
	} else {
	    rv = str_to_discrete_event_state(states, &st);
	}
	if (rv)
	    return rv;
	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_event_enable_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_disable_events(self, st, sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	free(st);
	return rv;
    }

    /* Get the event enables for the given sensor.  When done, the
     * sensor_get_event_enable_cb method on the first parameter will
     * be called with the following parameters: <self> <sensor> <err>
     * <event states> */
    int get_event_enables(swig_cb handler)
    {
	int                          rv;
	swig_cb_val                  handler_val = NULL;
	ipmi_sensor_event_enables_cb sensor_cb = NULL;

	if (!valid_swig_cb(handler))
	    return EINVAL;

	sensor_cb = sensor_get_event_enables_handler;
	handler_val = ref_swig_cb(handler);
	rv = ipmi_sensor_get_event_enables(self, sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Rearm the current sensor.  This will cause the sensor to resend
     * it's current event state if it is out of range.  If
     * get_supports_auto_rearm() returns false and you receive an
     * event, you have to rearm a sensor manually to get another event
     * from it.  If global_enable (parm 1) is set, all events are
     * enabled and the state is ignored (and may be NULL).  Otherwise,
     * the events set in the event state (parm 2) are enabled.  When
     * the operation is complete, the sensor_rearm_cb method of the
     * third parameter will be called with the following parameters:
     * <self> <sensor> <err>
     */
    int rearm(int     global_enable,
	      char    *states,
	      swig_cb handler = NULL)
    {
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;
	ipmi_event_state_t  *st = NULL;

	if (!global_enable) {
	    if (!states)
		return EINVAL;
	    if (ipmi_sensor_get_event_reading_type(self)
		== IPMI_EVENT_READING_TYPE_THRESHOLD)
	    {
		rv = str_to_threshold_event_state(states, &st);
	    } else {
		rv = str_to_discrete_event_state(states, &st);
	    }
	    if (rv)
		return rv;
	}
	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_rearm_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_rearm(self, global_enable, st,
			       sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	if (st)
	    free(st);
	return rv;
    }

    /*
     * Get the hysteresis values for the given sensor.  These are the
     * raw values, there doesn't seem to be an easy way to calculate
     * the cooked values.  The sensr_get_hysteresis_cb method on the
     * first parameter will be called with the values.  It's
     * parameters are: <self> <sensor> <err> <positive hysteresis>
     * <negative hysteresis>
     */
    int get_hysteresis(swig_cb handler)
    {
	int                       rv;
	swig_cb_val               handler_val = NULL;
	ipmi_sensor_hysteresis_cb sensor_cb = NULL;

	if (!valid_swig_cb(handler))
	    return EINVAL;

	sensor_cb = sensor_get_hysteresis_handler;
	handler_val = ref_swig_cb(handler);
	rv = ipmi_sensor_get_hysteresis(self, sensor_cb, handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Set the hysteresis values for the given sensor.  These are the
     * raw values, there doesn't seem to be an easy way to calculate
     * the cooked values.  The positive hysteresis is the first
     * parameter, the negative hystersis is the second.  When the
     * operation completes, the sensor_set_hysteresis_cb will be
     * called on the third parameters with the following parms:
     * <self> <sensor> <err>
     */
    int set_hysteresis(unsigned int positive_hysteresis,
		       unsigned int negative_hysteresis,
		       swig_cb      handler)
    {
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;

	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_set_hysteresis_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_set_hysteresis(self, positive_hysteresis,
					negative_hysteresis,
					sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    %newobject get_default_thresholds;
    /* Return the default threshold settings for a sensor. */
    char *get_default_thresholds()
    {
	ipmi_thresholds_t *th = malloc(ipmi_thresholds_size());
	char              *str = NULL;
	int               rv;

	rv = ipmi_get_default_sensor_thresholds(self, th);
	if (!rv) {
	    str = thresholds_to_str(th);
	}
	free(th);
	return str;
    }

    /*
     * Set the thresholds for the given sensor to the threshold values
     * specified in the first parameter.  When the thresholds are set,
     * the sensor_set_thresholds_cb method on the second parm will be
     * called with the following parameters: <self> <sensor> <err>
     */
    int set_thresholds(char    *thresholds,
		       swig_cb handler)
    {
	ipmi_thresholds_t   *th;
	int                 rv;
	swig_cb_val         handler_val = NULL;
	ipmi_sensor_done_cb sensor_cb = NULL;

	rv = str_to_thresholds(thresholds, &th);
	if (rv)
	    return rv;

	if (valid_swig_cb(handler)) {
	    sensor_cb = sensor_set_thresholds_handler;
	    handler_val = ref_swig_cb(handler);
	}
	rv = ipmi_sensor_set_thresholds(self, th, sensor_cb, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Fetch the thresholds for the given sensor.  When the thresholds
     * are received, the sensor_get_thresholds_cb method on the second
     * parm will be called with the following parameters: <self>
     * <sensor> <err> <thresholds>
     */
    int get_thresholds(swig_cb handler)
    {
	int                       rv;
	swig_cb_val               handler_val = NULL;
	ipmi_sensor_thresholds_cb sensor_cb = NULL;

	if (!valid_swig_cb(handler))
	    return EINVAL;

	sensor_cb = sensor_get_thresholds_handler;
	handler_val = ref_swig_cb(handler);
	rv = ipmi_sensor_get_thresholds(self, sensor_cb, handler_val);
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /* Read the current value of the given sensor.  If this is a
       discrete sensor, the discrete_states_cb method of the first
       parameter will be called with the following parameters: <self>
       <sensor> <err> <states>.  If this is a threshold sensor, the
       threshold_reading_cb method of the first parameter will be
       called with the following parameters: <self> <sensor> <err>
       <raw_set> <raw> <value_set> <value> <states>. */
    int get_value(swig_cb handler)
    {
	int                    rv;
	swig_cb_val            handler_val = NULL;

	if (!valid_swig_cb(handler))
	    return EINVAL;

	handler_val = ref_swig_cb(handler);
	if (ipmi_sensor_get_event_reading_type(self)
	    == IPMI_EVENT_READING_TYPE_THRESHOLD)
	{
	    ipmi_sensor_reading_cb sensor_cb;

	    sensor_cb = sensor_get_reading_handler;
	    rv = ipmi_sensor_get_reading(self, sensor_cb, handler_val);
	} else {
	    ipmi_sensor_states_cb sensor_cb;

	    sensor_cb = sensor_get_states_handler;
	    rv = ipmi_sensor_get_states(self, sensor_cb, handler_val);
	}
	if (rv)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /* 
     * Return the LUN for the sensor (with respect to the MC).
     */
    int get_lun()
    {
	int lun = 0;
	ipmi_sensor_get_num(self, &lun, NULL);
	return lun;
    }

    /* 
     * Return the number for the sensor (The number in the MC/LUN).
     */
    int get_num()
    {
	int num = 0;
	ipmi_sensor_get_num(self, NULL, &num);
	return num;
    }

    /*
     * The sensor type.  This return sa string representing the sensor
     * type.
     */
    char *get_sensor_type_string()
    {
	return ipmi_sensor_get_sensor_type_string(self);
    }

#define SENSOR_TYPE_TEMPERATURE				0x01
#define SENSOR_TYPE_VOLTAGE				0x02
#define SENSOR_TYPE_CURRENT				0x03
#define SENSOR_TYPE_FAN					0x04
#define SENSOR_TYPE_PHYSICAL_SECURITY			0x05
#define SENSOR_TYPE_PLATFORM_SECURITY			0x06
#define SENSOR_TYPE_PROCESSOR				0x07
#define SENSOR_TYPE_POWER_SUPPLY			0x08
#define SENSOR_TYPE_POWER_UNIT				0x09
#define SENSOR_TYPE_COOLING_DEVICE			0x0a
#define SENSOR_TYPE_OTHER_UNITS_BASED_SENSOR		0x0b
#define SENSOR_TYPE_MEMORY				0x0c
#define SENSOR_TYPE_DRIVE_SLOT				0x0d
#define SENSOR_TYPE_POWER_MEMORY_RESIZE			0x0e
#define SENSOR_TYPE_SYSTEM_FIRMWARE_PROGRESS		0x0f
#define SENSOR_TYPE_EVENT_LOGGING_DISABLED		0x10
#define SENSOR_TYPE_WATCHDOG_1				0x11
#define SENSOR_TYPE_SYSTEM_EVENT			0x12
#define SENSOR_TYPE_CRITICAL_INTERRUPT			0x13
#define SENSOR_TYPE_BUTTON				0x14
#define SENSOR_TYPE_MODULE_BOARD			0x15
#define SENSOR_TYPE_MICROCONTROLLER_COPROCESSOR		0x16
#define SENSOR_TYPE_ADD_IN_CARD				0x17
#define SENSOR_TYPE_CHASSIS				0x18
#define SENSOR_TYPE_CHIP_SET				0x19
#define SENSOR_TYPE_OTHER_FRU				0x1a
#define SENSOR_TYPE_CABLE_INTERCONNECT			0x1b
#define SENSOR_TYPE_TERMINATOR				0x1c
#define SENSOR_TYPE_SYSTEM_BOOT_INITIATED		0x1d
#define SENSOR_TYPE_BOOT_ERROR				0x1e
#define SENSOR_TYPE_OS_BOOT				0x1f
#define SENSOR_TYPE_OS_CRITICAL_STOP			0x20
#define SENSOR_TYPE_SLOT_CONNECTOR			0x21
#define SENSOR_TYPE_SYSTEM_ACPI_POWER_STATE		0x22
#define SENSOR_TYPE_WATCHDOG_2				0x23
#define SENSOR_TYPE_PLATFORM_ALERT			0x24
#define SENSOR_TYPE_ENTITY_PRESENCE			0x25
#define SENSOR_TYPE_MONITOR_ASIC_IC			0x26
#define SENSOR_TYPE_LAN					0x27
#define SENSOR_TYPE_MANAGEMENT_SUBSYSTEM_HEALTH		0x28
#define SENSOR_TYPE_BATTERY				0x29
    /*
     * Return the numeric sensor type.
     */
    int get_sensor_type()
    {
	return ipmi_sensor_get_sensor_type(self);
    }

    /*
     * Return the event reading type string.  If this returns
     * "threshold", then this is a threshold sensor.  Otherwise it is
     * a discrete sensor.
     */
    char *get_event_reading_type_string()
    {
	return ipmi_sensor_get_event_reading_type_string(self);
    }

#define EVENT_READING_TYPE_THRESHOLD				0x01
#define EVENT_READING_TYPE_DISCRETE_USAGE			0x02
#define EVENT_READING_TYPE_DISCRETE_STATE			0x03
#define EVENT_READING_TYPE_DISCRETE_PREDICTIVE_FAILURE		0x04
#define EVENT_READING_TYPE_DISCRETE_LIMIT_EXCEEDED		0x05
#define EVENT_READING_TYPE_DISCRETE_PERFORMANCE_MET		0x06
#define EVENT_READING_TYPE_DISCRETE_SEVERITY			0x07
#define EVENT_READING_TYPE_DISCRETE_DEVICE_PRESENCE		0x08
#define EVENT_READING_TYPE_DISCRETE_DEVICE_ENABLE		0x09
#define EVENT_READING_TYPE_DISCRETE_AVAILABILITY		0x0a
#define EVENT_READING_TYPE_DISCRETE_REDUNDANCY			0x0b
#define EVENT_READING_TYPE_DISCRETE_ACPI_POWER			0x0c
#define EVENT_READING_TYPE_SENSOR_SPECIFIC			0x6f
    /*
     * Return the numeric event reading type.  This will return
     * EVENT_READING_TYPE_THRESHOLD for threshold sensors; everthing
     * else is a discrete sensor.
     */
    int get_event_reading_type()
    {
	return ipmi_sensor_get_event_reading_type(self);
    }

    /*
     * Get the string for the sensor's rate unit.  This will be blank
     * if there is not a rate unit for this sensor.
     */
    char *get_rate_unit_string()
    {
	return ipmi_sensor_get_rate_unit_string(self);
    }

#define RATE_UNIT_NONE		0
#define RATE_UNIT_PER_US	1
#define RATE_UNIT_PER_MS	2
#define RATE_UNIT_PER_SEC	3
#define RATE_UNIT_MIN		4
#define RATE_UNIT_HOUR		5
#define RATE_UNIT_DAY		6

    /*
     * Get the rate unit for this sensor.
     */
    int get_rate_unit()
    {
	return ipmi_sensor_get_rate_unit(self);
    }

    /*
     * Get the string for the sensor's base unit.
     */
    char *get_base_unit_string()
    {
	return ipmi_sensor_get_base_unit_string(self);
    }

#define IPMI_UNIT_TYPE_UNSPECIFIED		0
#define IPMI_UNIT_TYPE_DEGREES_C		1
#define IPMI_UNIT_TYPE_DEGREES_F		2
#define IPMI_UNIT_TYPE_DEGREES_K		3
#define IPMI_UNIT_TYPE_VOLTS			4
#define IPMI_UNIT_TYPE_AMPS			5
#define IPMI_UNIT_TYPE_WATTS			6
#define IPMI_UNIT_TYPE_JOULES			7
#define IPMI_UNIT_TYPE_COULOMBS			8
#define IPMI_UNIT_TYPE_VA			9
#define IPMI_UNIT_TYPE_NITS			10
#define IPMI_UNIT_TYPE_LUMENS			11
#define IPMI_UNIT_TYPE_LUX			12
#define IPMI_UNIT_TYPE_CANDELA			13
#define IPMI_UNIT_TYPE_KPA			14
#define IPMI_UNIT_TYPE_PSI			15
#define IPMI_UNIT_TYPE_NEWTONS			16
#define IPMI_UNIT_TYPE_CFM			17
#define IPMI_UNIT_TYPE_RPM			18
#define IPMI_UNIT_TYPE_HZ			19
#define IPMI_UNIT_TYPE_USECONDS			20
#define IPMI_UNIT_TYPE_MSECONDS			21
#define IPMI_UNIT_TYPE_SECONDS			22
#define IPMI_UNIT_TYPE_MINUTE			23
#define IPMI_UNIT_TYPE_HOUR			24
#define IPMI_UNIT_TYPE_DAY			25
#define IPMI_UNIT_TYPE_WEEK			26
#define IPMI_UNIT_TYPE_MIL			27
#define IPMI_UNIT_TYPE_INCHES			28
#define IPMI_UNIT_TYPE_FEET			29
#define IPMI_UNIT_TYPE_CUBIC_INCHS		30
#define IPMI_UNIT_TYPE_CUBIC_FEET		31
#define IPMI_UNIT_TYPE_MILLIMETERS		32
#define IPMI_UNIT_TYPE_CENTIMETERS		33
#define IPMI_UNIT_TYPE_METERS			34
#define IPMI_UNIT_TYPE_CUBIC_CENTIMETERS	35
#define IPMI_UNIT_TYPE_CUBIC_METERS		36
#define IPMI_UNIT_TYPE_LITERS			37
#define IPMI_UNIT_TYPE_FL_OZ			38
#define IPMI_UNIT_TYPE_RADIANS			39
#define IPMI_UNIT_TYPE_SERADIANS		40
#define IPMI_UNIT_TYPE_REVOLUTIONS		41
#define IPMI_UNIT_TYPE_CYCLES			42
#define IPMI_UNIT_TYPE_GRAVITIES		43
#define IPMI_UNIT_TYPE_OUNCES			44
#define IPMI_UNIT_TYPE_POUNDS			45
#define IPMI_UNIT_TYPE_FOOT_POUNDS		46
#define IPMI_UNIT_TYPE_OUNCE_INCHES		47
#define IPMI_UNIT_TYPE_GAUSS			48
#define IPMI_UNIT_TYPE_GILBERTS			49
#define IPMI_UNIT_TYPE_HENRIES			50
#define IPMI_UNIT_TYPE_MHENRIES			51
#define IPMI_UNIT_TYPE_FARADS			52
#define IPMI_UNIT_TYPE_UFARADS			53
#define IPMI_UNIT_TYPE_OHMS			54
#define IPMI_UNIT_TYPE_SIEMENS			55
#define IPMI_UNIT_TYPE_MOLES			56
#define IPMI_UNIT_TYPE_BECQUERELS		57
#define IPMI_UNIT_TYPE_PPM			58
#define IPMI_UNIT_TYPE_reserved1		59
#define IPMI_UNIT_TYPE_DECIBELS			60
#define IPMI_UNIT_TYPE_DbA			61
#define IPMI_UNIT_TYPE_DbC			62
#define IPMI_UNIT_TYPE_GRAYS			63
#define IPMI_UNIT_TYPE_SIEVERTS			64
#define IPMI_UNIT_TYPE_COLOR_TEMP_DEG_K		65
#define IPMI_UNIT_TYPE_BITS			66
#define IPMI_UNIT_TYPE_KBITS			67
#define IPMI_UNIT_TYPE_MBITS			68
#define IPMI_UNIT_TYPE_GBITS			69
#define IPMI_UNIT_TYPE_BYTES			70
#define IPMI_UNIT_TYPE_KBYTES			71
#define IPMI_UNIT_TYPE_MBYTES			72
#define IPMI_UNIT_TYPE_GBYTES			73
#define IPMI_UNIT_TYPE_WORDS			74
#define IPMI_UNIT_TYPE_DWORDS			75
#define IPMI_UNIT_TYPE_QWORDS			76
#define IPMI_UNIT_TYPE_LINES			77
#define IPMI_UNIT_TYPE_HITS			78
#define IPMI_UNIT_TYPE_MISSES			79
#define IPMI_UNIT_TYPE_RETRIES			80
#define IPMI_UNIT_TYPE_RESETS			81
#define IPMI_UNIT_TYPE_OVERRUNS			82
#define IPMI_UNIT_TYPE_UNDERRUNS		83
#define IPMI_UNIT_TYPE_COLLISIONS		84
#define IPMI_UNIT_TYPE_PACKETS			85
#define IPMI_UNIT_TYPE_MESSAGES			86
#define IPMI_UNIT_TYPE_CHARACTERS		87
#define IPMI_UNIT_TYPE_ERRORS			88
#define IPMI_UNIT_TYPE_CORRECTABLE_ERRORS	89	
#define IPMI_UNIT_TYPE_UNCORRECTABLE_ERRORS	90
#define IPMI_UNIT_TYPE_FATAL_ERRORS		91
#define IPMI_UNIT_TYPE_GRAMS			92

    /*
     * Get the sensor's base unit.
     */
    int get_base_unit()
    {
	return ipmi_sensor_get_base_unit(self);
    }

    /*
     * Get the modifier unit string for the sensor, this will be an empty
     * string if there is none.
     */
    char *get_modifier_unit_string()
    {
	return ipmi_sensor_get_modifier_unit_string(self);
    }

    /*
     * Get the sensor's modifier unit.
     */
    int get_modifier_unit()
    {
	return ipmi_sensor_get_modifier_unit(self);
    }

#define MODIFIER_UNIT_NONE		0
#define MODIFIER_UNIT_BASE_DIV_MOD	1
#define MODIFIER_UNIT_BASE_MULT_MOD	2

    /*
     * Return the how the modifier unit should be used.  If this
     * returns MODIFIER_UNIT_NONE, then the modifier unit is not
     * used.  If it returns MODIFIER_UNIT_BASE_DIV_MOD, the modifier
     * unit is dividied by the base unit (eg per hour, per second,
     * etc.).  If it returns MODIFIER_UNIT_BASE_MULT_MOD, the modifier
     * unit is multiplied by the base unit.
     */
    int get_modifier_unit_use()
    {
	return ipmi_sensor_get_modifier_unit_use(self);
    }


    /*
     * This call is a little different from the other string calls.
     * For a discrete sensor, you can pass the offset into this call
     * and it will return the string associated with the reading.
     * This way, OEM sensors can supply their own strings as necessary
     * for the various offsets.  This is only for discrete sensors.
     */
    char *reading_name_string(int offset)
    {
	return ipmi_sensor_reading_name_string(self, offset);
    }

    /*
     * Get the entity id of the entity the sensor is hooked to.
     */
    int get_entity_id()
    {
	return ipmi_sensor_get_entity_id(self);
    }

    /*
     * Get the entity instance of the entity the sensor is hooked to.
     */
    int get_entity_instance()
    {
	return ipmi_sensor_get_entity_instance(self);
    }

    /*
     * Get the entity the sensor is hooked to.
     */
    ipmi_entity_t *get_entity()
    {
	return ipmi_sensor_get_entity(self);
    }


    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_scanning()
    {
	return ipmi_sensor_get_sensor_init_scanning(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_events()
    {
	return ipmi_sensor_get_sensor_init_events(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_thresholds()
    {
	return ipmi_sensor_get_sensor_init_thresholds(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_hysteresis()
    {
	return ipmi_sensor_get_sensor_init_hysteresis(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_type()
    {
	return ipmi_sensor_get_sensor_init_type(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_pu_events()
    {
	return ipmi_sensor_get_sensor_init_pu_events(self);
    }

    /*
     * Initialization information about a sensor from it's SDR.
     */
    int get_sensor_init_pu_scanning()
    {
	return ipmi_sensor_get_sensor_init_pu_scanning(self);
    }

    /*
     * Ignore the sensor if the entity it is attached to is not
     * present.
     */
    int get_ignore_if_no_entity()
    {
	return ipmi_sensor_get_ignore_if_no_entity(self);
    }

    /*
     * If this is false, the user must manually re-arm the sensor to get
     * any more events from it.
     */
    int get_supports_auto_rearm()
    {
	return ipmi_sensor_get_supports_auto_rearm(self);
    }


#define THRESHOLD_ACCESS_SUPPORT_NONE		0
#define THRESHOLD_ACCESS_SUPPORT_READABLE	1
#define THRESHOLD_ACCESS_SUPPORT_SETTABLE	2
#define THRESHOLD_ACCESS_SUPPORT_FIXED		3

    /*
     * Get how the thresholds of the sensor may be accessed.
     */
    int get_threshold_access()
    {
	return ipmi_sensor_get_threshold_access(self);
    }

#define HYSTERESIS_SUPPORT_NONE		0
#define HYSTERESIS_SUPPORT_READABLE	1
#define HYSTERESIS_SUPPORT_SETTABLE	2
#define HYSTERESIS_SUPPORT_FIXED	3

    /*
     * Get how the hysteresis of the sensor may be accessed.
     */
    int get_hysteresis_support()
    {
	return ipmi_sensor_get_hysteresis_support(self);
    }

#define EVENT_SUPPORT_PER_STATE		0
#define EVENT_SUPPORT_ENTIRE_SENSOR	1
#define EVENT_SUPPORT_GLOBAL_ENABLE	2
#define EVENT_SUPPORT_NONE		3

    /*
     * Get how the events in the sensor may be enabled and disabled.
     */
    int get_event_support()
    {
	return ipmi_sensor_get_event_support(self);
    }

#define SENSOR_DIRECTION_UNSPECIFIED	0
#define SENSOR_DIRECTION_INPUT		1
#define SENSOR_DIRECTION_OUTPUT		2

    /*
     * Get whether the sensor is monitoring an input or an output.
     * For instance, the +5V sensor on the output of a power supply
     * would be the output, the +5V sensor measuring the voltage
     * coming into a card would be an input.
     */
    int get_sensor_direction()
    {
	return ipmi_sensor_get_sensor_direction(self);
    }

    /*
     * Sets the second parameter to if an event is supported for this
     * particular threshold event on the sensor. The first parameter
     * is the event specifier string.  This will return 0 on success
     * or EINVAL on an invalid event.
     */
    int threshold_event_supported(char *event, int *val)
    {
	enum ipmi_thresh_e          thresh;
	enum ipmi_event_value_dir_e value_dir;
	enum ipmi_event_dir_e       dir;
	char                        *s;

	s = threshold_event_from_str(event, strlen(event), &thresh,
				      &value_dir, &dir);
	if (!s)
	    return EINVAL;
	return ipmi_sensor_threshold_event_supported(self,
						     thresh,
						     value_dir,
						     dir,
						     val);
    }

    /*
     * Sets the second parameter to if a specific threshold can be
     * set.  The first parameter is the threshold.  Returns EINVAL
     * if the threshold is invalid, otherwise returns zero.
     */
    int threshold_settable(char *threshold, int *val)
    {
	enum ipmi_thresh_e thresh;
	char               *s;

	s = threshold_from_str(threshold, strlen(threshold), &thresh);
	if (!s)
	    return EINVAL;
	return ipmi_sensor_threshold_settable(self, thresh, val);
    }

    /*
     * Sets the second parameter to if a specific threshold can be
     * read.  The first parameter is the threshold.  Returns EINVAL
     * if the threshold is invalid, otherwise returns zero.
     */
    int threshold_readable(char *threshold, int *val)
    {
	enum ipmi_thresh_e thresh;
	char               *s;

	s = threshold_from_str(threshold, strlen(threshold), &thresh);
	if (!s)
	    return EINVAL;
	return ipmi_sensor_threshold_readable(self, thresh, val);
    }

    /*
     * Sets the second parameter to if a specific threshold has its
     * reading returned when reading the value of the sensor.  The
     * first parameter is the threshold.  Returns EINVAL if the
     * threshold is invalid, otherwise returns zero.
     */
    int threshold_reading_supported(char *threshold, int *val)
    {
	enum ipmi_thresh_e thresh;
	char               *s;

	s = threshold_from_str(threshold, strlen(threshold), &thresh);
	if (!s)
	    return EINVAL;
	return ipmi_sensor_threshold_reading_supported(self, thresh, val);
    }

    /*
     * Sets the second parameter to if an offset will generate an
     * event for the given event specifier for this particular
     * sensor. The first parameter is the event specifier string.
     * This will return 0 on success or EINVAL on an invalid event.
     */
    int discrete_event_supported(char *event, int *val)
    {
	int                   offset;
	enum ipmi_event_dir_e dir;
	char                  *s;

	s = discrete_event_from_str(event, strlen(event), &offset, &dir);
	if (!s)
	    return EINVAL;
	return ipmi_sensor_discrete_event_supported(self, offset, dir, val);
    }

    /*
     * Sets the second parameter to if a specific offset is set by the
     * sensor.  The first parameter is the offset.  Returns EINVAL if
     * the threshold is invalid, otherwise returns zero.
     */
    int discrete_event_readable(int offset, int *val)
    {
	return ipmi_sensor_discrete_event_readable(self, offset, val);
    }

    /*
     * Returns if the value is a percentage.
     */
    int get_percentage()
    {
	return ipmi_sensor_get_percentage(self);
    }

    /*
     * Returns the tolerance for the sensor at the given raw value
     * (first parameter).  The tolerance is returned as a double in
     * the second parameter.  Returns an error value.
     */
    int get_tolerance(int val, double *tolerance)
    {
	return ipmi_sensor_get_tolerance(self, val, tolerance);
    }

    /*
     * Returns the accuracy for the sensor at the given raw value
     * (first parameter).  The accuracy is returned as a double in the
     * second parameter.  Returns an error value.
     */
    int get_accuracy(int val, double *accuracy)
    {
	return ipmi_sensor_get_accuracy(self, val, accuracy);
    }

    /*
     * Is the normal minimum for the sensor specified?
     */
    int get_normal_min_specified()
    {
	return ipmi_sensor_get_normal_min_specified(self);
    }

    /*
     * Get the normal minimum for the sensor into the first parameter.
     * Returns an error value.
     */
    int get_normal_min(double *normal_min)
    {
	return ipmi_sensor_get_normal_min(self, normal_min);
    }

    /*
     * Is the normal maximum for the sensor specified?
     */
    int get_normal_max_specified()
    {
	return ipmi_sensor_get_normal_max_specified(self);
    }

    /*
     * Get the normal maximum for the sensor into the first parameter.
     * Returns an error value.
     */
    int get_normal_max(double *normal_max)
    {
	return ipmi_sensor_get_normal_max(self, normal_max);
    }

    /*
     * Returns if the nominal reading for the sensor is specified.
     */
    int get_nominal_reading_specified()
    {
	return ipmi_sensor_get_nominal_reading_specified(self);
    }

    /*
     * Get the nominal value for the sensor into the first parameter.
     * Returns an error value.
     */
    int get_nominal_reading(double *nominal_reading)
    {
	return ipmi_sensor_get_nominal_reading(self, nominal_reading);
    }

    /*
     * Get the sensor maximum for the sensor into the first parameter.
     * Returns an error value.
     */
    int get_sensor_max(double *sensor_max)
    {
	return ipmi_sensor_get_sensor_max(self, sensor_max);
    }

    /*
     * Get the sensor minimum for the sensor into the first parameter.
     * Returns an error value.
     */
    int get_sensor_min(double *sensor_min)
    {
	return ipmi_sensor_get_sensor_min(self, sensor_min);
    }

    /*
     * Get the OEM value from the sensor's SDR.
     */
    int get_oem1()
    {
	return ipmi_sensor_get_oem1(self);
    }

    %newobject get_sensor_id;
    /*
     * Get the ID string from the sensor's SDR.
     */
    char *get_sensor_id()
    {
	/* FIXME - no unicode handling. */
	int len = ipmi_sensor_get_id_length(self) + 1;
	char *id = malloc(len);
	ipmi_sensor_get_id(self, id, len);
	return id;
    }
}

/*
 * A control id object.  This object is guaranteed to be valid and
 * can be converted into a mc pointer later.
 */
%extend ipmi_control_id_t {
    ~ipmi_control_id_t()
    {
	free(self);
    }

    /*
     * Convert a control id to a control pointer.  The "control_cb" method
     * will be called on the first parameter with the following parameters:
     * <self> <control>
     */
    char *convert_to_control(swig_cb handler)
    {
	int rv;

	if (! valid_swig_cb(handler))
	    return NULL;

	rv = ipmi_control_pointer_cb(*self, handle_control_cb,
				    get_swig_cb(handler));
	if (rv)
	    return strerror(rv);
	return NULL;
    }
}

/*
 * An control object
 */
%extend ipmi_control_t {
    %newobject get_name;
    /*
     * Get the name of an control.
     */
    char *get_name()
    {
	char name[IPMI_CONTROL_NAME_LEN];

	ipmi_control_get_name(self, name, sizeof(name));
	return strdup(name);
    }

    %newobject get_id;
    /*
     * Get the id for the control.
     */
    ipmi_control_id_t *get_id()
    {
	ipmi_control_id_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_control_convert_to_id(self);
	return rv;
    }

    /*
     * Get the string type of control.
     */
    char *get_type_string()
    {
	return ipmi_control_get_type_string(self);
    }

#define CONTROL_LIGHT		1
#define CONTROL_RELAY		2
#define CONTROL_DISPLAY		3
#define CONTROL_ALARM		4
#define CONTROL_RESET		5
#define CONTROL_POWER		6
#define CONTROL_FAN_SPEED	7
#define CONTROL_IDENTIFIER	8
#define CONTROL_ONE_SHOT_RESET	9
#define CONTROL_OUTPUT		10
#define CONTROL_ONE_SHOT_OUTPUT	11

    /*
     * Get the numeric type of control.
     */
    int get_type()
    {
	return ipmi_control_get_type(self);
    }

    /*
     * Get the entity id for the control's entity.
     */
    int get_entity_id()
    {
	return ipmi_control_get_entity_id(self);
    }

    /*
     * Get the entity instance for the control's entity.
     */
    int get_entity_instance()
    {
	return ipmi_control_get_entity_instance(self);
    }

    /*
     * Get the entity for the control.
     */
    ipmi_entity_t *get_entity()
    {
	return ipmi_control_get_entity(self);
    }

    /*
     * Can the control's value be set?
     */
    int is_settable()
    {
	return ipmi_control_is_settable(self);
    }

    /*
     * Can the control's value be read?
     */
    int is_readable()
    {
	return ipmi_control_is_readable(self);
    }

    /*
     * Should the control be ignored if its entity is not present?
     */
    int get_ignore_if_no_entity()
    {
	return ipmi_control_get_ignore_if_no_entity(self);
    }

    %newobject get_control_id;
    /*
     * Get the ID string from the control's SDR.
     */
    char *get_control_id()
    {
	/* FIXME - no unicode handling. */
	int len = ipmi_control_get_id_length(self) + 1;
	char *id = malloc(len);
	ipmi_control_get_id(self, id, len);
	return id;
    }

    /*
     * Returns true if the control can generate events upon change,
     * and false if not.
     */
    int has_events()
    {
	return ipmi_control_has_events(self);
    }

    /*
     * Get the number of values the control supports.
     */
    int get_num_vals()
    {
	return ipmi_control_get_num_vals(self);
    }


    /*
     * Set the value of a control.  Note that an control may support
     * more than one element, the array reference passed in as the
     * first parameter must match the number of elements the control
     * supports.  All the elements will be set simultaneously.  The
     * control_set_val_cb method on the second parameter will be called
     * after the operation completes with.  It will be called with the
     * following parameters: <self> <contro> <err>
     */
    int set_val(intarray val, swig_cb handler)
    {
	swig_cb_val        handler_val = NULL;
	ipmi_control_op_cb done = NULL;
	int                rv;

	if (val.len != ipmi_control_get_num_vals(self))
	    return EINVAL;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_set_handler;
	}
	rv = ipmi_control_set_val(self, val.val, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Get the setting of an control.  The control_get_val_cb method
     * on the first parameter will be called with the following
     * parameters: <self> <control> <err> <val1> [<val2> ...]. The
     * number of values passed to the handler will be the number of
     * values the control supports.
     */
    int get_val(swig_cb handler)
    {
	swig_cb_val        handler_val = NULL;
	ipmi_control_val_cb done = NULL;
	int                rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_get_handler;
	}
	rv = ipmi_control_get_val(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Register a handler that will be called when the control changes
     * value.  Note that if the control does not support this
     * operation, it will return ENOSYS.  When a control event comes
     * in, the control_event_val_cb method on the first parameter will
     * be called with the following parameters: <self> <control>
     * <valid1> [<valid2> ...] val1 [<val2> ...].  The valid fields
     * tell if a particular value is corrected, the number of these
     * is the same as what get_num_vals() returns for this control.
     * the val fields are the actual values, the value is valid only
     * if the valid field corresponding to it is true.
     */
    int add_event_handler(swig_cb handler)
    {
	cb_add(control, val_event);
    }

    /*
     * Remove a control event handler.
     */
    int remove_event_handler(swig_cb handler)
    {
	cb_rm(control, val_event);
    }

#define CONTROL_COLOR_BLACK	0
#define CONTROL_COLOR_WHITE	1
#define CONTROL_COLOR_RED	2
#define CONTROL_COLOR_GREEN	3
#define CONTROL_COLOR_BLUE	4
#define CONTROL_COLOR_YELLOW	5
#define CONTROL_COLOR_ORANGE	6

    /*
     * This describes a setting for a light.  There are two types of
     * lights.  One type has a general ability to be set to a color, on
     * time, and off time.  The other has a pre-defined set of
     * transitions.  For transition-based lights, each light is defined to
     * go through a number of transitions.  Each transition is described
     * by a color, a time (in milliseconds) that the color is present.
     * For non-blinking lights, there will only be one transition.  For
     * blinking lights, there will be one or more transitions.
     */

    /*
     * If this returns true, then you set the light with the
     * set_light() function and get the values with the get_light()
     * function.  Otherwise you get/set it with the normal
     * get_val/set_valfunctions and use the transitions functions to
     * get what the LED can do.
     */
    int light_set_with_setting()
    {
	return ipmi_control_light_set_with_setting(self);
    }

    /*
     * Convert the given color to a string.
     */
    char *color_string(int color)
    {
	return ipmi_get_color_string(color);
    }

    /*
     * Allows detecting if a setting light supports a specific
     * color.
     */
    int light_is_color_supported(int color)
    {
	return ipmi_control_light_is_color_supported(self, color);
    }

    /*
     * Returns true if the light has a local control mode, false if
     * not.
     */
    int light_has_local_control()
    {
	return ipmi_control_light_has_local_control(self);
    }

    /*
     * Set a setting style light's settings.  The first parm is a
     * string in the form:
     * "[lc] <color> <on_time> <off time>[:[lc] <color>...]".  The
     * second parm turns on or off local control of the light.  When
     * the operation is complete the control_set_val_cb method on the
     * second parameter will be called.
     */
    int ipmi_control_set_light(char *settings, swig_cb handler)
    {
	ipmi_light_setting_t *s;
	int                  rv;
	swig_cb_val          handler_val = NULL;
	ipmi_control_op_cb   done = NULL;

	rv = str_to_light_setting(settings, &s);
	if (rv)
	    return rv;

	if (ipmi_light_setting_get_count(s)
	    != ipmi_control_get_num_vals(self))
	{
	    free(s);
	    return EINVAL;
	}

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_set_handler;
	}
	rv = ipmi_control_set_light(self, s, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	ipmi_free_light_settings(s);
	return rv;
    }

    /*
     * Get the current values of the light.  The control_get_light_cb
     * method on the first parm will be called with the following
     * parameters: <self> <err> <light settings>
     * The light settings is a string with each light separated by
     * colons with the (optional) local control (lc), color, on, and
     * off time like this:
     * "[lc] <color> <on_time> <off time>[:[lc] <color>...]"
     */
    int ipmi_control_get_light(swig_cb handler)
    {
	swig_cb_val            handler_val = NULL;
	ipmi_light_settings_cb done = NULL;
	int                    rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_get_light_handler;
	}
	rv = ipmi_control_get_light(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }
		       
    /*
     * For lights that are transition based, this returns the number
     * of values for a specific light.  So if you put a 2 in the first
     * parm, this will return the number of possible settings for the
     * 3rd light.
     */
    int get_num_light_values(int light)
    {
	return ipmi_control_get_num_light_values(self, light);
    }

    /*
     * For lights that are transition based, return the number of
     * transitions for the given light and value setting.  So if you
     * put a 1 and a 3, this returns the number of transitions that
     * the second light will go through if you set it's value to 3.
     * Each transition will have a color and duration time and can be
     * fetched with other values.  Returns -1 if the inputs are
     * invalid.
     */
    int get_num_light_transitions(int light, int value)
    {
	return ipmi_control_get_num_light_transitions(self, light, value);
    }

    /*
     * For lights that are transition based, return the color of the
     * given transition.  Returns -1 if the inputs are invalid.
     */
    int get_light_color(int light, int value, int transition)
    {
	return ipmi_control_get_light_color(self, light, value, transition);
    }

    /*
     * For lights that are transition based, return the duration of
     * the given transition.  Returns -1 if the inputs are invalid.
     */
    int get_light_color_time(int light, int value, int transition)
    {
	return ipmi_control_get_light_color_time(self, light, value,
						 transition);
    }

    /*
     * Set the value of the identifier.  The first parameter is a
     * reference to an array of byte values to se the identifier to.
     * When the setting is complete, the control_set_val_cb method on
     * the second parameter will be called.
     */
    int identifier_set_val(intarray val, swig_cb handler)
    {
	swig_cb_val        handler_val = NULL;
	ipmi_control_op_cb done = NULL;
	int                rv;
	unsigned char      *data;
	int                i;


	data = malloc(val.len);
	for (i=0; i<val.len; i++)
	    data[i] = val.val[i];

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_set_handler;
	}
	rv = ipmi_control_identifier_set_val(self, data, val.len,
					     done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	free(data);
	return rv;
    }

    /*
     * Get the value of the identifier control.  The control_get_id_cb
     * method on the first parameter will be called when the operation
     * completes.  The values passed to that method will be:
     * <self> <err> byte1 [<byte2> ...].
     * The id value is all the bytes after the error value.
     */
    int identifier_get_val(swig_cb handler)
    {
	swig_cb_val                    handler_val = NULL;
	ipmi_control_identifier_val_cb done = NULL;
	int                            rv;

	if (valid_swig_cb(handler)) {
	    handler_val = ref_swig_cb(handler);
	    done = control_val_get_id_handler;
	}
	rv = ipmi_control_identifier_get_val(self, done, handler_val);
	if (rv && handler_val)
	    deref_swig_cb_val(handler_val);
	return rv;
    }

    /*
     * Return the maximum possible length of the identifier control's
     * value.
     */
    int identifier_get_max_length()
    {
	return ipmi_control_identifier_get_max_length(self);
    }
}

/*
 * A FRU object
 */
%extend ipmi_fru_t {
}

/*
 * An event object
 */
%extend ipmi_event_t {
    ~ipmi_event_t()
    {
	ipmi_event_free(self);
    }

    %newobject get_mc_id;
    /*
     * Get the MC id the event came from.  Note that the MC may not exist
     * any more.
     */
    ipmi_mcid_t *get_mc_id()
    {
	ipmi_mcid_t *rv = malloc(sizeof(*rv));
	if (rv)
	    *rv = ipmi_event_get_mcid(self);
	return rv;
    }

    /*
     * Get the event's record id
     */
    int get_record_id()
    {
	return ipmi_event_get_record_id(self);
    }

    /*
     * Get the event's type.
     */
    int get_type()
    {
	return ipmi_event_get_type(self);
    }

    /*
     * Get the event's timestamp.  This is in seconds.
     */
    double get_timestamp()
    {
	return ((double) ipmi_event_get_timestamp(self)) / 1000000000.0;
    }

    /*
     * Get the data from the event.  This returns a reference to an
     * array, so you have to reference it like @$val.
     */
    intarray get_data()
    {
	intarray      rv;
	int           i;
	unsigned char *data;
	int           data_len;

	data_len = ipmi_event_get_data_len(self);
	data = malloc(data_len);
	data_len = ipmi_event_get_data(self, data, 0, data_len);
	rv.val = malloc(sizeof(int) * data_len);
	for (i=0; i<data_len; i++)
	    rv.val[i] = data[i];
	free(data);
	rv.len = data_len;
	return rv;
    }
}