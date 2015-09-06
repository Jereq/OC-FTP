using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Proxy
{
	class Program
	{
		static void Main(string[] args)
		{
			var driverListener = new TcpListener(IPAddress.Any, 16900);

			while (true)
			{
				driverListener.Start();
				var driverSocket = driverListener.AcceptSocket();
				driverListener.Stop();

				Console.WriteLine("Driving host connected: " + driverSocket.RemoteEndPoint);
				handleOne(driverSocket);
			}
		}

		class DriverState
		{
			public Socket socket;
			public byte[] receiveBuffer = new byte[1024];
			public int receivedBytes = 0;
			public byte[] sendBuffer = new byte[1024];

			public Dictionary<int, ListenerState> listeningPorts = new Dictionary<int, ListenerState>();
			public Dictionary<int, ConnectionState> connections = new Dictionary<int, ConnectionState>();
			public int nextId = 1;
		}

		class ListenerState
		{
			public TcpListener listener;
			public DriverState driver;
			public int port;
		}

		class ConnectionState
		{
			public Socket socket;
			public byte[] sendBuffer = new byte[1024];
			public byte[] receiveBuffer = new byte[1024];
			public DriverState driver;
			public int id;
		}

		class SendPayloadState
		{
			public int bytesToReceive;
			public ConnectionState target;
		}

		private static void handleOne(Socket driverSocket)
		{
			var state = new DriverState { socket = driverSocket };

			StartReceiveCommand(state);
		}

		private static void StartReceiveCommand(DriverState state)
		{
			state.receivedBytes = 0;
			state.socket.BeginReceive(state.receiveBuffer, state.receivedBytes, 1, SocketFlags.None, new AsyncCallback(OnCommandDataReceived), state);
		}

		private static void OnCommandDataReceived(IAsyncResult result)
		{
			var state = (DriverState)result.AsyncState;
			int bytes;
			try
			{
				bytes = state.socket.EndReceive(result);
			}
			catch (SocketException)
			{
				Console.WriteLine("Driver closed");

				state.socket.Shutdown(SocketShutdown.Both);
				state.socket.Close();

				foreach (var l in state.listeningPorts)
				{
					l.Value.listener.Stop();
				}
				state.listeningPorts.Clear();

				foreach (var c in state.connections)
				{
					c.Value.socket.Shutdown(SocketShutdown.Both);
					c.Value.socket.Close();
				}
				state.connections.Clear();
				return;
			}

			if (bytes == 0)
			{
				state.socket.Shutdown(SocketShutdown.Both);
				state.socket.Close();

				foreach (var l in state.listeningPorts)
				{
					l.Value.listener.Stop();
				}
				state.listeningPorts.Clear();

				foreach (var c in state.connections)
				{
					c.Value.socket.Shutdown(SocketShutdown.Both);
					c.Value.socket.Close();
				}
				state.connections.Clear();
				return;
			}

			if (state.receiveBuffer[state.receivedBytes] == '\n')
			{
				HandleCommand(state);
			}
			else
			{
				state.receivedBytes++;
				state.socket.BeginReceive(state.receiveBuffer, state.receivedBytes, 1, SocketFlags.None, new AsyncCallback(OnCommandDataReceived), state);
			}
		}

		private static void HandleCommand(DriverState state)
		{
			var parts = Encoding.ASCII.GetString(state.receiveBuffer, 0, state.receivedBytes).Split(' ');

			var cmd = parts[0];

			if (cmd == "LISTEN")
			{
				Console.WriteLine("Creating listening port " + parts[1]);

				var port = int.Parse(parts[1]);
                var newListeningPort = new TcpListener(IPAddress.Any, port);
				newListeningPort.Start();

				var acceptState = new ListenerState { listener = newListeningPort, driver = state, port = port };
				state.listeningPorts.Add(acceptState.port, acceptState);

				StartReceiveCommand(state);
			}
			else if (cmd == "STOP_LISTEN")
			{
				Console.WriteLine("Stopping listening port " + parts[1]);

				var port = int.Parse(parts[1]);
				var listenerState = state.listeningPorts[port];
				listenerState.listener.Stop();
				state.listeningPorts.Remove(port);

				StartReceiveCommand(state);
			}
			else if (cmd == "CLOSE_CONNECTION")
			{
				Console.WriteLine("Closing connection " + parts[1]);

				var connectionId = int.Parse(parts[1]);
				var connectionState = state.connections[connectionId];
				connectionState.socket.Shutdown(SocketShutdown.Both);
				connectionState.socket.Close();
				state.connections.Remove(connectionId);
				
				StartReceiveCommand(state);
			}
			else if (cmd == "ACCEPT_ONE")
			{
				Console.WriteLine("Accepting one connection on port " + parts[1]);

				var port = int.Parse(parts[1]);
				var listenerState = state.listeningPorts[port];
				listenerState.listener.BeginAcceptSocket(new AsyncCallback(OnAcceptSocketOnce), listenerState);
				
				StartReceiveCommand(state);
			}
			else if (cmd == "ACCEPT_ALL")
			{
				Console.WriteLine("Accepting all connections on port " + parts[1]);

				var port = int.Parse(parts[1]);
				var listenerState = state.listeningPorts[port];
				listenerState.listener.BeginAcceptSocket(new AsyncCallback(OnAcceptSocket), listenerState);

				StartReceiveCommand(state);
			}
			else if (cmd == "SEND")
			{
				Console.WriteLine("Sending " + parts[2] + " bytes to " + parts[1]);

				var connectionId = int.Parse(parts[1]);
				var messageLength = int.Parse(parts[2]);
				var payloadState = new SendPayloadState
				{
					bytesToReceive = messageLength,
					target = state.connections[connectionId]
				};
				state.socket.BeginReceive(state.receiveBuffer, 0, Math.Min(payloadState.bytesToReceive, state.receiveBuffer.Length),
					SocketFlags.None, new AsyncCallback(OnPayloadReceived), payloadState);
			}
			else if (cmd == "READ_ONCE")
			{
				Console.WriteLine("Reading once (max " + parts[2] + " bytes) from " + parts[1]);

				var connectionId = int.Parse(parts[1]);
				var maxBytes = int.Parse(parts[2]);
				var connectionState = state.connections[connectionId];
				if (maxBytes == 0)
				{
					maxBytes = connectionState.receiveBuffer.Length;
                }
				connectionState.socket.BeginReceive(connectionState.receiveBuffer, 0, maxBytes, SocketFlags.None, new AsyncCallback(OnReceiveClientDataOnce), connectionState);

				StartReceiveCommand(state);
			}
			else if (cmd == "READ_ALL")
			{
				Console.WriteLine("Reading all from " + parts[1]);

				var connectionId = int.Parse(parts[1]);
				var connectionState = state.connections[connectionId];
				connectionState.socket.BeginReceive(connectionState.receiveBuffer, 0, connectionState.receiveBuffer.Length, SocketFlags.None, new AsyncCallback(OnReceiveClientData), connectionState);

				StartReceiveCommand(state);
			}
			else
			{
				Console.WriteLine("Unknown command: " + string.Join(" ", parts));
			}
		}

		private static void OnPayloadReceived(IAsyncResult result)
		{
			var state = (SendPayloadState)result.AsyncState;
			var driver = state.target.driver;

			var receivedBytes = driver.socket.EndReceive(result);
			Debug.Assert(receivedBytes > 0);

			state.bytesToReceive -= receivedBytes;

			Array.Copy(driver.receiveBuffer, state.target.sendBuffer, receivedBytes);

			state.target.socket.Send(state.target.sendBuffer, receivedBytes, SocketFlags.None);

			if (state.bytesToReceive == 0)
			{
				StartReceiveCommand(driver);
			}
			else
			{
				driver.socket.BeginReceive(driver.receiveBuffer, 0, Math.Min(state.bytesToReceive, driver.receiveBuffer.Length),
					SocketFlags.None, new AsyncCallback(OnPayloadReceived), state);
			}
		}

		private static void OnAcceptSocket(IAsyncResult result)
		{
			var state = (ListenerState)result.AsyncState;
			if (!TryAcceptSocket(result))
				return;

			state.listener.BeginAcceptSocket(new AsyncCallback(OnAcceptSocket), state);
		}

		private static void OnAcceptSocketOnce(IAsyncResult result)
		{
			TryAcceptSocket(result);
		}

		private static bool TryAcceptSocket(IAsyncResult result)
		{
			var state = (ListenerState)result.AsyncState;

			Socket client;
			try
			{
				client = state.listener.EndAcceptSocket(result);
			}
			catch (ObjectDisposedException)
			{
				return false; // Listener stopped
			}

			var connectionId = state.driver.nextId++;
			var msg = "CONNECTION " + state.port + " " + connectionId + "\n";
			var conState = new ConnectionState { socket = client, driver = state.driver, id = connectionId };
			state.driver.connections.Add(connectionId, conState);

			Encoding.ASCII.GetBytes(msg, 0, msg.Length, state.driver.sendBuffer, 0);
			state.driver.socket.Send(state.driver.sendBuffer, msg.Length, SocketFlags.None);

			Console.WriteLine("Connection got: " + client.RemoteEndPoint);

			return true;
		}

		private static void OnReceiveClientData(IAsyncResult result)
		{
			var state = (ConnectionState)result.AsyncState;
			if (!TryReceiveClientData(result))
				return;

			state.socket.BeginReceive(state.receiveBuffer, 0, state.receiveBuffer.Length, SocketFlags.None, new AsyncCallback(OnReceiveClientData), state);
		}

		private static void OnReceiveClientDataOnce(IAsyncResult result)
		{
			TryReceiveClientData(result);
		}

		private static bool TryReceiveClientData(IAsyncResult result)
		{
			var state = (ConnectionState)result.AsyncState;

			int receivedBytes;
			try
			{
				receivedBytes = state.socket.EndReceive(result);
			}
			catch (ObjectDisposedException)
			{
				var closed = "CLOSED " + state.id + "\n";
				Encoding.ASCII.GetBytes(closed, 0, closed.Length, state.driver.sendBuffer, 0);
				state.driver.connections.Remove(state.id);
				return false; // Socket closed
			}
			catch (SocketException ex)
			{
				Console.Error.WriteLine(ex);
				var closed = "CLOSED " + state.id + "\n";
				Encoding.ASCII.GetBytes(closed, 0, closed.Length, state.driver.sendBuffer, 0);
				state.driver.socket.Send(state.driver.sendBuffer, closed.Length, SocketFlags.None);
				state.socket.Shutdown(SocketShutdown.Both);
				state.socket.Close();
				state.driver.connections.Remove(state.id);
				return false;
			}

			if (receivedBytes == 0)
			{
				var closed = "CLOSED " + state.id + "\n";
				Encoding.ASCII.GetBytes(closed, 0, closed.Length, state.driver.sendBuffer, 0);
				state.driver.socket.Send(state.driver.sendBuffer, closed.Length, SocketFlags.None);
				state.socket.Shutdown(SocketShutdown.Both);
				state.socket.Close();
				state.driver.connections.Remove(state.id);
				return false;
			}

			var got = Encoding.ASCII.GetBytes("DATA " + state.id + " " + receivedBytes + "\n");

			Array.Copy(got, state.driver.sendBuffer, got.Length);
			state.driver.socket.Send(state.driver.sendBuffer, got.Length, SocketFlags.None);

			Array.Copy(state.receiveBuffer, state.driver.sendBuffer, receivedBytes);
			state.driver.socket.Send(state.driver.sendBuffer, receivedBytes, SocketFlags.None);

			return true;
		}
	}
}
