/**************************************************************************/
/*  midi_driver_coremidi.mm                                               */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#import "midi_driver_coremidi.h"

#ifdef COREMIDI_ENABLED

#include "core/string/print_string.h"

#import <CoreFoundation/CoreFoundation.h>

Mutex MIDIDriverCoreMidi::mutex;
bool MIDIDriverCoreMidi::core_midi_closed = false;

MIDIDriverCoreMidi::InputConnection::InputConnection(int p_device_index, MIDIEndpointRef p_source) :
		parser(p_device_index), source(p_source) {}

void MIDIDriverCoreMidi::read(const MIDIPacketList *packet_list, void *read_proc_ref_con, void *src_conn_ref_con) {
	MutexLock lock(mutex);
	if (!core_midi_closed) {
		MIDIDriverCoreMidi *driver = static_cast<MIDIDriverCoreMidi *>(read_proc_ref_con);
		InputConnection *source = static_cast<InputConnection *>(src_conn_ref_con);
		// After a close and reopen, a late callback from the old port may still arrive: only parse into live connections.
		if (!driver->connected_sources.has(source)) {
			return;
		}
		const MIDIPacket *packet = packet_list->packet;
		for (UInt32 packet_index = 0; packet_index < packet_list->numPackets; packet_index++) {
			for (UInt16 data_index = 0; data_index < packet->length; data_index++) {
				source->parser.parse_fragment(packet->data[data_index]);
			}
			packet = MIDIPacketNext(packet);
		}
	}
}

// Called on the run loop of the thread that created the client (the main thread). A device plugged in, unplugged, or showing up as a
// new source after replugging does not change the open connections by itself: reconnect every source so get_connected_inputs() lists
// exactly the devices present and new sources get connected, without the app having to close and reopen. Sources still present are
// reconnected too, so their next messages keep arriving.
void MIDIDriverCoreMidi::notify(const MIDINotification *message, void *ref_con) {
	MIDIDriverCoreMidi *driver = static_cast<MIDIDriverCoreMidi *>(ref_con);
	if (message->messageID == kMIDIMsgSetupChanged && driver->client && !core_midi_closed) {
		driver->close();
		driver->open();
	}
}

Error MIDIDriverCoreMidi::open() {
	// The client and port live until the driver is destroyed: close() only disconnects the sources, so an app can close and reopen
	// to pick up devices plugged in since. Disposing the last client of a process can make the MIDI server quit, and recreating
	// clients repeatedly has been seen to fail (MIDIClientCreate -2), losing every device.
	ERR_FAIL_COND_V_MSG(client && !core_midi_closed, FAILED, "MIDIDriverCoreMidi is already open.");

	mutex.lock();
	core_midi_closed = false;
	mutex.unlock();

	if (!client) {
		CFStringRef name = CFStringCreateWithCString(nullptr, "Godot", kCFStringEncodingASCII);
		OSStatus result = MIDIClientCreate(name, MIDIDriverCoreMidi::notify, (void *)this, &client);
		CFRelease(name);
		if (result != noErr) {
			client = 0;
			ERR_PRINT("MIDIClientCreate failed, code: " + itos(result));
			return ERR_CANT_OPEN;
		}

		// The port is made together with the client (a live client always has a port), so the next open retries both on failure.
		result = MIDIInputPortCreate(client, CFSTR("Godot Input"), MIDIDriverCoreMidi::read, (void *)this, &port_in);
		if (result != noErr) {
			MIDIClientDispose(client);
			client = 0;
			ERR_PRINT("MIDIInputPortCreate failed, code: " + itos(result));
			return ERR_CANT_OPEN;
		}
	}

	int source_count = MIDIGetNumberOfSources();
	int connection_index = 0;
	for (int i = 0; i < source_count; i++) {
		MIDIEndpointRef source = MIDIGetSource(i);
		if (source) {
			InputConnection *conn = memnew(InputConnection(connection_index, source));
			const OSStatus res = MIDIPortConnectSource(port_in, source, static_cast<void *>(conn));
			if (res != noErr) {
				memdelete(conn);
			} else {
				mutex.lock();
				connected_sources.push_back(conn);
				mutex.unlock();

				CFStringRef nameRef = nullptr;
				char name[256];
				MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &nameRef);
				CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8);
				CFRelease(nameRef);
				connected_input_names.push_back(name);

				connection_index++; // Contiguous index for successfully connected inputs.
			}
		}
	}

	return OK;
}

void MIDIDriverCoreMidi::close() {
	mutex.lock();
	core_midi_closed = true;
	mutex.unlock();

	for (InputConnection *conn : connected_sources) {
		MIDIPortDisconnectSource(port_in, conn->source);
		memdelete(conn);
	}

	connected_sources.clear();
	connected_input_names.clear();
}

MIDIDriverCoreMidi::~MIDIDriverCoreMidi() {
	close();

	if (client != 0) {
		MIDIPortDispose(port_in);
		MIDIClientDispose(client);
		client = 0;
	}
}

#endif // COREMIDI_ENABLED
