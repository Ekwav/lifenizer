using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace lifenizer
{
    /// <summary>
    /// Helper for handling extern processes, starting stopping
    /// </summary>
    public class ProcessHandler
    {
        List<Process> processes = new List<Process>();

        public static ProcessHandler Instance {get; protected set;}

        static ProcessHandler()
        {
            Instance = new ProcessHandler();
        }

        public ProcessHandler()
        {
            
            Console.CancelKeyPress += delegate {
                Console.WriteLine("abording");
                foreach (var p in processes)
                {
                    p.Kill();
                }
            };
        }

        public void RegisterProcess(Process process)
        {
            processes.Add(process);
        }

        public Process RunCommandline(string programm, string command)
        {
            command = command.Replace("{data}",Program.DefaultDataPath);

            var startInfo = new ProcessStartInfo();
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.UseShellExecute = false;
            startInfo.FileName = programm;
            startInfo.Arguments = command;

            var p = Process.Start(startInfo);
            p.OutputDataReceived += (ev,a) => {
                Console.WriteLine("found " + a.Data.Replace(Program.DefaultDataPath,""));
            };
            RegisterProcess(p);
            return p;
        }
    }
}