/*
 * ipmi_smi.h
 *
 * MontaVista IPMI code for handling system management connections
 *
 * Author: MontaVista Software, Inc.
 *         Corey Minyard <minyard@mvista.com>
 *         source@mvista.com
 *
 * Copyright 2002 MontaVista Software Inc.
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

#include <malloc.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/poll.h>
#include <sys/time.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

#include <linux/ipmi.h>
#include <ipmi/ipmi_conn.h>
#include <ipmi/ipmi_msgbits.h>
#include <ipmi/ipmi_int.h>
#include <ipmi/ipmi_smi.h>
#include <ipmi/ipmi_err.h>

#ifdef DEBUG_MSG
static void
dump_hex(unsigned char *data, int len)
{
    int i;
    for (i=0; i<len; i++) {
	if ((i != 0) && ((i % 16) == 0)) {
	    ipmi_log("\n  ");
	}
	ipmi_log(" %2.2x", data[i]);
    }
}
#endif

typedef struct pending_cmd_s
{
    ipmi_con_t            *ipmi;
    int                   cancelled;
    ipmi_msg_t            msg;
    ipmi_addr_t           addr;
    unsigned int          addr_len;
    ipmi_ll_rsp_handler_t rsp_handler;
    void                  *rsp_data;
    void                  *data2, *data3;
    struct pending_cmd_s  *next, *prev;
    os_hnd_timer_id_t     *timeout_id;
} pending_cmd_t;

typedef struct cmd_handler_s
{
    unsigned char         netfn;
    unsigned char         cmd;
    ipmi_ll_cmd_handler_t handler;
    void                  *cmd_data;
    void                  *data2, *data3;

    struct cmd_handler_s *next, *prev;
} cmd_handler_t;

struct ipmi_ll_event_handler_id_s
{
    ipmi_con_t            *ipmi;
    ipmi_ll_evt_handler_t handler;
    void                  *event_data;
    void                  *data2;

    ipmi_ll_event_handler_id_t *next, *prev;
};

typedef struct smi_data_s
{
    ipmi_con_t                 *ipmi;
    int                        fd;
    int                        if_num;
    pending_cmd_t              *pending_cmds;
    ipmi_lock_t                *cmd_lock;
    cmd_handler_t              *cmd_handlers;
    ipmi_lock_t                *cmd_handlers_lock;
    os_hnd_fd_id_t             *fd_wait_id;
    ipmi_ll_event_handler_id_t *event_handlers;
    ipmi_lock_t                *event_handlers_lock;

    struct smi_data_s *next, *prev;
} smi_data_t;

static smi_data_t *smi_list = NULL;

/* Must be called with the ipmi read or write lock. */
static int smi_valid_ipmi(ipmi_con_t *ipmi)
{
    smi_data_t *elem;

    elem = smi_list;
    while ((elem) && (elem->ipmi != ipmi)) {
	elem = elem->next;
    }

    return (elem != NULL);
}

/* Must be called with cmd_lock held. */
static void
add_cmd(ipmi_con_t    *ipmi,
	ipmi_addr_t   *addr,
	unsigned int  addr_len,
	ipmi_msg_t    *msg,
	smi_data_t    *smi,
	pending_cmd_t *cmd)
{
    cmd->ipmi = ipmi;
    memcpy(&(cmd->addr), addr, addr_len);
    cmd->addr_len = addr_len;
    cmd->msg = *msg;
    cmd->msg.data = NULL;

    cmd->next = smi->pending_cmds;
    cmd->prev = NULL;
    if (smi->pending_cmds)
	smi->pending_cmds->prev = cmd;
    smi->pending_cmds = cmd;
}

static void
remove_cmd(ipmi_con_t    *ipmi,
	   smi_data_t    *smi,
	   pending_cmd_t *cmd)
{
    if (cmd->next)
	cmd->next->prev = cmd->prev;
    if (cmd->prev)
	cmd->prev->next = cmd->next;
    else
	smi->pending_cmds = cmd->next;
}

/* Must be called with event_lock held. */
static void
add_event_handler(ipmi_con_t                 *ipmi,
		  smi_data_t                 *smi,
		  ipmi_ll_event_handler_id_t *event)
{
    event->ipmi = ipmi;

    event->next = smi->event_handlers;
    event->prev = NULL;
    if (smi->event_handlers)
	smi->event_handlers->prev = event;
    smi->event_handlers = event;
}

static void
remove_event_handler(smi_data_t                 *smi,
		     ipmi_ll_event_handler_id_t *event)
{
    if (event->next)
	event->next->prev = event->prev;
    if (event->prev)
	event->prev->next = event->next;
    else
	smi->event_handlers = event->next;
}

static int
add_cmd_registration(ipmi_con_t            *ipmi,
		     unsigned char         netfn,
		     unsigned char         cmd,
		     ipmi_ll_cmd_handler_t handler,
		     void                  *cmd_data,
		     void                  *data2,
		     void                  *data3)
{
    cmd_handler_t *elem, *finder;
    smi_data_t    *smi = (smi_data_t *) ipmi->con_data;

    elem = malloc(sizeof(*elem));
    if (!elem)
	return ENOMEM;

    elem->netfn = netfn;
    elem->cmd = cmd;
    elem->handler = handler;
    elem->cmd_data = cmd_data;
    elem->data2 = data2;
    elem->data3 = data3;

    ipmi_lock(smi->cmd_handlers_lock);
    finder = smi->cmd_handlers;
    while (finder != NULL) {
	if ((finder->netfn == netfn) && (finder->cmd == cmd)) {
	    ipmi_unlock(smi->cmd_handlers_lock);
	    free(elem);
	    return EEXIST;
	}
	finder = finder->next;
    }

    elem->next = smi->cmd_handlers;
    elem->prev = NULL;
    if (smi->cmd_handlers)
	smi->cmd_handlers->prev = elem;
    smi->cmd_handlers = elem;
    ipmi_unlock(smi->cmd_handlers_lock);

    return 0;
}

int
remove_cmd_registration(ipmi_con_t    *ipmi,
			unsigned char netfn,
			unsigned char cmd)
{
    smi_data_t    *smi = (smi_data_t *) ipmi->con_data;
    cmd_handler_t *elem;

    ipmi_lock(smi->cmd_handlers_lock);
    elem = smi->cmd_handlers;
    while (elem != NULL) {
	if ((elem->netfn == netfn) && (elem->cmd == cmd))
	    break;

	elem = elem->next;
    }
    if (!elem) {
	ipmi_unlock(smi->cmd_handlers_lock);
	return ENOENT;
    }

    if (elem->next)
	elem->next->prev = elem->prev;
    if (elem->prev)
	elem->prev->next = elem->next;
    else
	smi->cmd_handlers = elem->next;
    ipmi_unlock(smi->cmd_handlers_lock);

    return 0;
}

static int
open_smi_fd(int if_num)
{
    char devname[30];
    int  fd;

    sprintf(devname, "/dev/ipmidev/%d", if_num);
    fd = open(devname, O_RDWR);
    if (fd == -1) {
	sprintf(devname, "/dev/ipmi/%d", if_num);
	fd = open(devname, O_RDWR);
	if (fd == -1) {
	    sprintf(devname, "/dev/ipmi%d", if_num);
	    fd = open(devname, O_RDWR);
	}
    }

    return fd;
}

static int
smi_send(smi_data_t   *smi,
	 int          fd,
	 ipmi_addr_t  *addr,
	 unsigned int addr_len,
	 ipmi_msg_t   *msg,
	 long         msgid)
{
    ipmi_req_t     req;

    if (DEBUG_MSG) {
	ipmi_log("outgoing, addr = ");
	dump_hex((unsigned char *) addr, addr_len);
	ipmi_log("\nmsg (netfn=%2.2x, cmd=%2.2x):\n  ", msg->netfn, msg->cmd);
	dump_hex(msg->data, msg->data_len);
	ipmi_log("\n");
    }
    req.addr = (unsigned char *) addr;
    req.addr_len = addr_len;
    req.msgid = (long) smi;
    req.msg = *msg;
    req.msgid = msgid;
    if (ioctl(fd, IPMICTL_SEND_COMMAND, &req) == -1)
	return errno;

    return 0;
}

static void
rsp_timeout_handler(void              *cb_data,
		    os_hnd_timer_id_t *id)
{
    pending_cmd_t         *cmd = (pending_cmd_t *) cb_data;
    ipmi_con_t            *ipmi = cmd->ipmi;
    smi_data_t            *smi;
    ipmi_msg_t            msg;
    unsigned char         data[1];

    ipmi_read_lock();

    /* If we were cancelled, just free the data and ignore it. */
    if (cmd->cancelled) {
	goto out_unlock2;
    }

    if (!smi_valid_ipmi(ipmi)) {
	goto out_unlock2;
    }

    smi = (smi_data_t *) ipmi->con_data;

    ipmi_lock(smi->cmd_lock);
    remove_cmd(ipmi, smi, cmd);

    data[0] = IPMI_TIMEOUT_CC;
    msg.netfn = cmd->msg.netfn | 1;
    msg.cmd = cmd->msg.cmd;
    msg.data = data;
    msg.data_len = 1;
    ipmi_unlock(smi->cmd_lock);

    /* call the user handler. */
    cmd->rsp_handler(ipmi, &(cmd->addr), cmd->addr_len, &msg,
		     cmd->rsp_data, cmd->data2, cmd->data3);

 out_unlock2:
    ipmi_read_unlock();
    free(cmd);
}

static void
handle_response(ipmi_con_t *ipmi, ipmi_recv_t *recv)
{
    smi_data_t            *smi = (smi_data_t *) ipmi->con_data;
    pending_cmd_t         *cmd, *finder;
    int                   rv;
    ipmi_ll_rsp_handler_t rsp_handler;
    void                  *rsp_data;
    void                  *data2, *data3;

    cmd = (pending_cmd_t *) recv->msgid;
    
    ipmi_lock(smi->cmd_lock);

    finder = smi->pending_cmds;
    while (finder) {
	if (finder == cmd)
	    break;
	finder = finder->next;
    }
    if (!finder)
	/* The command was not found. */
	goto out_unlock;

    /* We have found the command, handle it. */

    /* Extract everything we need from the command here. */
    rsp_handler = cmd->rsp_handler;
    rsp_data = cmd->rsp_data;
    data2 = cmd->data2;
    data3 = cmd->data3;

    remove_cmd(ipmi, smi, cmd);

    rv = ipmi->os_hnd->remove_timer(ipmi->os_hnd, cmd->timeout_id);
    if (rv)
	/* Can't cancel the timer, so the timer will run, let the timer
	   free the command when that happens. */
	cmd->cancelled = 1;
    else
	free(cmd);

    cmd = NULL; /* It's gone after this point. */

    ipmi_unlock(smi->cmd_lock);

    /* call the user handler. */
    rsp_handler(ipmi,
		(ipmi_addr_t *) recv->addr, recv->addr_len,
		&(recv->msg), rsp_data, data2, data3);

 out_unlock:
    ipmi_unlock(smi->cmd_lock);
}

static void
handle_async_event(ipmi_con_t *ipmi, ipmi_recv_t *recv)
{
    smi_data_t                 *smi = (smi_data_t *) ipmi->con_data;
    ipmi_ll_event_handler_id_t *elem, *next;

    ipmi_lock(smi->event_handlers_lock);
    elem = smi->event_handlers;
    while (elem != NULL) {
	/* Fetch the next element now, so the user can delete the
           current one. */
	next = elem->next;

	/* call the user handler. */
	elem->handler(ipmi,
		      (ipmi_addr_t *) &(recv->addr), recv->addr_len,
		      &(recv->msg), elem->event_data, elem->data2);

	elem = next;
    }
    ipmi_unlock(smi->event_handlers_lock);
}

static void
handle_incoming_command(ipmi_con_t *ipmi, ipmi_recv_t *recv)
{
    smi_data_t    *smi = (smi_data_t *) ipmi->con_data;
    cmd_handler_t *elem;
    unsigned char netfn = recv->msg.netfn;
    unsigned char cmd_num = recv->msg.cmd;


    ipmi_lock(smi->cmd_handlers_lock);
    elem = smi->cmd_handlers;
    while (elem != NULL) {
	if ((elem->netfn == netfn) && (elem->cmd == cmd_num))
	    break;

	elem = elem->next;
    }
    if (!elem) {
	/* No handler, send an unhandled response and quit. */
	unsigned char data[1];
	ipmi_msg_t    msg;

	msg = recv->msg;
	msg.netfn |= 1; /* Make it into a response. */
	data[0] = IPMI_INVALID_CMD_CC;
	msg.data = data;
	msg.data_len = 1;
	smi_send(smi, smi->fd,
		 (ipmi_addr_t *) &(recv->addr), recv->addr_len,
		 &msg, recv->msgid);
	goto out_unlock;
    }

    elem->handler(ipmi,
		  (ipmi_addr_t *) &(recv->addr), recv->addr_len,
		  &(recv->msg), recv->msgid,
		  elem->cmd_data, elem->data2, elem->data3);

 out_unlock:
    ipmi_unlock(smi->cmd_handlers_lock);
}

static void
data_handler(int            fd,
	     void           *cb_data,
	     os_hnd_fd_id_t *id)
{
    ipmi_con_t    *ipmi = (ipmi_con_t *) cb_data;
    unsigned char data[MAX_IPMI_DATA_SIZE];
    ipmi_addr_t   addr;
    ipmi_recv_t   recv;
    int           rv;

    ipmi_read_lock();

    if (!smi_valid_ipmi(ipmi)) {
	/* We can have due to a race condition, just return and
           everything should be fine. */
	goto out_unlock2;
    }

    recv.msg.data = data;
    recv.msg.data_len = sizeof(data);
    recv.addr = (unsigned char *) &addr;
    recv.addr_len = sizeof(addr);
    rv = ioctl(fd, IPMICTL_RECEIVE_MSG_TRUNC, &recv);
    if (rv == -1) {
	if (errno == EMSGSIZE) {
	    /* The message was truncated, handle it as such. */
	    data[0] = IPMI_REQUESTED_DATA_LENGTH_EXCEEDED_CC;
	    rv = 0;
	} else
	    goto out_unlock2;
    }

    if (DEBUG_MSG) {
	ipmi_log("incoming, addr = ");
	dump_hex(recv.addr, recv.addr_len);
	ipmi_log("\nmsg (netfn=%2.2x, cmd=%2.2x):\n  ", recv.msg.netfn, 
		 recv.msg.cmd);
	dump_hex(recv.msg.data, recv.msg.data_len);
	ipmi_log("\n");
    }

    switch (recv.recv_type) {
	case IPMI_RESPONSE_RECV_TYPE:
	    handle_response(ipmi, &recv);
	    break;

	case IPMI_ASYNC_EVENT_RECV_TYPE:
	    handle_async_event(ipmi, &recv);
	    break;

	case IPMI_CMD_RECV_TYPE:
	    handle_incoming_command(ipmi, &recv);
	    break;

	default:
	    break;
    }

 out_unlock2:
    ipmi_read_unlock();
}

static int
smi_send_command(ipmi_con_t            *ipmi,
		 ipmi_addr_t           *addr,
		 unsigned int          addr_len,
		 ipmi_msg_t            *msg,
		 ipmi_ll_rsp_handler_t rsp_handler,
		 void                  *rsp_data,
		 void                  *data2,
		 void                  *data3)
{
    pending_cmd_t  *cmd;
    smi_data_t     *smi;
    struct timeval timeout;
    int            rv;


    smi = (smi_data_t *) ipmi->con_data;

    if (addr_len > sizeof(ipmi_addr_t)) {
	rv = EINVAL;
	goto out_unlock2;
    }

    cmd = malloc(sizeof(*cmd));
    if (!cmd) {
	rv = ENOMEM;
	goto out_unlock2;
    }

    /* Put it in the list first. */
    cmd->rsp_handler = rsp_handler;
    cmd->rsp_data = rsp_data;
    cmd->data2 = data2;
    cmd->data3 = data3;
    cmd->cancelled = 0;

    ipmi_lock(smi->cmd_lock);
    add_cmd(ipmi, addr, addr_len, msg, smi, cmd);

    timeout.tv_sec = IPMI_RSP_TIMEOUT / 1000;
    timeout.tv_usec = (IPMI_RSP_TIMEOUT % 1000) * 1000;
    rv = ipmi->os_hnd->add_timer(ipmi->os_hnd,
				 &timeout,
				 rsp_timeout_handler,
				 cmd,
				 &(cmd->timeout_id));
    if (rv) {
	remove_cmd(ipmi, smi, cmd);
	free(cmd);
	goto out_unlock;
    }

    rv = smi_send(smi, smi->fd, addr, addr_len, msg, (long) cmd);
    if (rv) {
	int err;

	remove_cmd(ipmi, smi, cmd);
	err = ipmi->os_hnd->remove_timer(ipmi->os_hnd, cmd->timeout_id);
	/* Special handling, if we can't remove the timer, then it
           will time out on us, so we need to not free the command and
           instead let the timeout handle freeing it. */
	if (!err)
	    free(cmd);
	else
	    cmd->cancelled = 1;
	goto out_unlock;
    }

 out_unlock:
    ipmi_unlock(smi->cmd_lock);
 out_unlock2:
    return rv;
}

static int
smi_register_for_events(ipmi_con_t                 *ipmi,
			ipmi_ll_evt_handler_t      handler,
			void                       *event_data,
			void                       *data2,
			ipmi_ll_event_handler_id_t **id)
{
    smi_data_t                 *smi;
    int                        rv = 0;
    int                        was_empty;
    ipmi_ll_event_handler_id_t *entry;

    smi = (smi_data_t *) ipmi->con_data;

    entry = malloc(sizeof(*entry));
    if (!entry) {
	rv = ENOMEM;
	goto out_unlock2;
    }

    entry->handler = handler;
    entry->event_data = event_data;
    entry->data2 = data2;

    ipmi_lock(smi->event_handlers_lock);
    was_empty = smi->event_handlers == NULL;

    add_event_handler(ipmi, smi, entry);

    if (was_empty) {
	int val = 1;
	rv = ioctl(smi->fd, IPMICTL_SET_GETS_EVENTS_CMD, &val);
	if (rv == -1) {
	    remove_event_handler(smi, entry);
	    rv = errno;
	    goto out_unlock;
	}
    }

 out_unlock:
    ipmi_unlock(smi->event_handlers_lock);
 out_unlock2:
    return rv;
}

static int
smi_deregister_for_events(ipmi_con_t                 *ipmi,
			  ipmi_ll_event_handler_id_t *id)
{
    smi_data_t *smi;
    int        rv = 0;

    smi = (smi_data_t *) ipmi->con_data;

    if (id->ipmi != ipmi) {
	rv = EINVAL;
	goto out_unlock2;
    }

    ipmi_lock(smi->event_handlers_lock);

    remove_event_handler(smi, id);
    id->ipmi = NULL;

    if (smi->event_handlers == NULL) {
	int val = 0;
	rv = ioctl(smi->fd, IPMICTL_SET_GETS_EVENTS_CMD, &val);
	if (rv == -1) {
	    rv = errno;
	    goto out_unlock;
	}
    }

 out_unlock:
    ipmi_unlock(smi->event_handlers_lock);
 out_unlock2:

    return rv;
}

static int
smi_send_response(ipmi_con_t   *ipmi,
		  ipmi_addr_t  *addr,
		  unsigned int addr_len,
		  ipmi_msg_t   *msg,
		  long         sequence)
{
    smi_data_t *smi;
    int        rv;

    smi = (smi_data_t *) ipmi->con_data;

    rv = smi_send(smi, smi->fd, addr, addr_len, msg, sequence);

    return rv;
}

static int
smi_register_for_command(ipmi_con_t            *ipmi,
			 unsigned char         netfn,
			 unsigned char         cmd,
			 ipmi_ll_cmd_handler_t handler,
			 void                  *cmd_data,
			 void                  *data2,
			 void                  *data3)
{
    smi_data_t     *smi;
    ipmi_cmdspec_t reg;
    int            rv;

    smi = (smi_data_t *) ipmi->con_data;

    rv = add_cmd_registration(ipmi, netfn, cmd, handler, cmd_data, data2, data3);
    if (rv)
	goto out_unlock;

    reg.netfn = netfn;
    reg.cmd = cmd;
    rv = ioctl(smi->fd, IPMICTL_REGISTER_FOR_CMD, &reg);
    if (rv == -1) {
	remove_cmd_registration(ipmi, netfn, cmd);
	return errno;
    }

 out_unlock:
    return rv;
}

static int
smi_deregister_for_command(ipmi_con_t    *ipmi,
			   unsigned char netfn,
			   unsigned char cmd)
{
    smi_data_t     *smi;
    ipmi_cmdspec_t reg;
    int            rv;

    smi = (smi_data_t *) ipmi->con_data;

    reg.netfn = netfn;
    reg.cmd = cmd;
    rv = ioctl(smi->fd, IPMICTL_UNREGISTER_FOR_CMD, &reg);
    if (rv == -1) {
	rv = errno;
	goto out_unlock;
    }

    remove_cmd_registration(ipmi, netfn, cmd);

 out_unlock:

    return 0;
}

static int
smi_close_connection(ipmi_con_t *ipmi)
{
    smi_data_t                 *smi;
    pending_cmd_t              *cmd_to_free, *next_cmd;
    cmd_handler_t              *hnd_to_free, *next_hnd;
    ipmi_ll_event_handler_id_t *evt_to_free, *next_evt;
    int                        rv;

    if (! smi_valid_ipmi(ipmi)) {
	return EINVAL;
    }

    /* First order of business is to remove it from the SMI list. */
    smi = (smi_data_t *) ipmi->con_data;

    if (smi->next)
	smi->next->prev = smi->prev;
    if (smi->prev)
	smi->prev->next = smi->next;
    else
	smi_list = smi->next;

    /* After this point no other operations can occur on this ipmi
       interface, so it's safe. */

    cmd_to_free = smi->pending_cmds;
    smi->pending_cmds = NULL;
    while (cmd_to_free) {
	next_cmd = cmd_to_free->next;
	rv = ipmi->os_hnd->remove_timer(ipmi->os_hnd, cmd_to_free->timeout_id);
	if (rv) {
	    cmd_to_free->cancelled = 1;
	    free(cmd_to_free);
	}
	cmd_to_free = next_cmd;
    }

    hnd_to_free = smi->cmd_handlers;
    smi->cmd_handlers = NULL;
    while (hnd_to_free) {
	next_hnd = hnd_to_free->next;
	free(hnd_to_free);
	hnd_to_free = next_hnd;
    }

    evt_to_free = smi->event_handlers;
    smi->event_handlers = NULL;
    while (evt_to_free) {
	evt_to_free->ipmi = NULL;
	next_evt = evt_to_free->next;
	free(evt_to_free);
	evt_to_free = next_evt;
    }

    if (smi->event_handlers_lock)
	ipmi_destroy_lock(smi->event_handlers_lock);
    if (smi->cmd_handlers_lock)
	ipmi_destroy_lock(smi->cmd_handlers_lock);
    if (smi->cmd_lock)
	ipmi_destroy_lock(smi->cmd_lock);
    if (smi->fd_wait_id)
	ipmi->os_hnd->remove_fd_to_wait_for(ipmi->os_hnd, smi->fd_wait_id);

    /* Close the fd after we have deregistered it. */
    close(smi->fd);

    free(smi);
    free(ipmi);

    return 0;
}

static ll_ipmi_t smi_ll_ipmi =
{
    .valid_ipmi = smi_valid_ipmi,
    .registered = 0
};

static void
cleanup_con(ipmi_con_t *ipmi)
{
    smi_data_t   *smi = (smi_data_t *) ipmi->con_data;
    os_handler_t *handlers = ipmi->os_hnd;

    if (ipmi) {
	free(ipmi);
    }

    if (smi) {
	if (smi->event_handlers_lock)
	    ipmi_destroy_lock(smi->event_handlers_lock);
	if (smi->cmd_handlers_lock)
	    ipmi_destroy_lock(smi->cmd_handlers_lock);
	if (smi->cmd_lock)
	    ipmi_destroy_lock(smi->cmd_lock);
	if (smi->fd != -1)
	    close(smi->fd);
	if (smi->fd_wait_id)
	    handlers->remove_fd_to_wait_for(ipmi->os_hnd, smi->fd_wait_id);
	free(smi);
    }
}

static int
setup(int          if_num,
      os_handler_t *handlers,
      void         *user_data,
      ipmi_con_t   **new_con)
{
    ipmi_con_t *ipmi = NULL;
    smi_data_t *smi = NULL;
    int        rv;

    /* Make sure we register before anything else. */
    ipmi_register_ll(&smi_ll_ipmi);

    /* Keep things sane. */
    if (if_num >= 100)
	return EINVAL;

    ipmi = malloc(sizeof(*ipmi));
    if (!ipmi)
	return ENOMEM;

    ipmi->user_data = user_data;
    ipmi->os_hnd = handlers;

    smi = malloc(sizeof(*smi));
    if (!smi) {
	rv = ENOMEM;
	goto out_err;
    }
    ipmi->con_data = smi;

    smi->ipmi = ipmi;
    smi->pending_cmds = NULL;
    smi->cmd_lock = NULL;
    smi->cmd_handlers = NULL;
    smi->cmd_handlers_lock = NULL;
    smi->event_handlers = NULL;
    smi->event_handlers_lock = NULL;
    smi->fd_wait_id = NULL;

    smi->fd = open_smi_fd(if_num);
    if (smi->fd == -1) {
	rv = errno;
	goto out_err;
    }

    /* Create the locks if they are available. */
    rv = ipmi_create_lock_os_hnd(handlers, &smi->cmd_lock);
    if (rv)
	goto out_err;

    rv = ipmi_create_lock_os_hnd(handlers, &smi->cmd_handlers_lock);
    if (rv)
	goto out_err;

    rv = ipmi_create_lock_os_hnd(handlers, &smi->event_handlers_lock);
    if (rv)
	goto out_err;

    smi->if_num = if_num;

    ipmi->send_command = smi_send_command;
    ipmi->register_for_events = smi_register_for_events;
    ipmi->deregister_for_events = smi_deregister_for_events;
    ipmi->send_response = smi_send_response;
    ipmi->register_for_command = smi_register_for_command;
    ipmi->deregister_for_command = smi_deregister_for_command;
    ipmi->close_connection = smi_close_connection;

    rv = handlers->add_fd_to_wait_for(ipmi->os_hnd,
				      smi->fd,
				      data_handler, 
				      ipmi,
				      &(smi->fd_wait_id));
    if (rv) {
	goto out_err;
    }

    /* Now it's valid, add it to the smi list. */
    ipmi_write_lock();
    if (smi_list)
	smi_list->prev = smi;
    smi->next = smi_list;
    smi->prev = NULL;
    smi_list = smi;
    ipmi_write_unlock();

    *new_con = ipmi;

    return 0;

 out_err:
    cleanup_con(ipmi);
    return rv;
}

int
ipmi_smi_setup_con(int               if_num,
		   os_handler_t      *handlers,
		   void              *user_data,
		   ipmi_setup_done_t setup_cb,
		   void              *cb_data)
{
    ipmi_con_t                   *con;
    int                          err;
    ipmi_system_interface_addr_t addr;

    if (!handlers->add_fd_to_wait_for
	|| !handlers->remove_fd_to_wait_for
	|| !handlers->add_timer
	|| !handlers->remove_timer)
	return ENOSYS;

    err = setup(if_num, handlers, user_data, &con);
    if (!err) {
	addr.addr_type = IPMI_SYSTEM_INTERFACE_ADDR_TYPE;
	addr.channel = IPMI_BMC_CHANNEL;
	con->setup_cb = setup_cb;
	con->setup_cb_data = cb_data;
	err = ipmi_init_con(con, (ipmi_addr_t *) &addr, sizeof(addr));
	if (err)
	    cleanup_con(con);
    }

    return err;
}