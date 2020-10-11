using System.Collections.Generic;
using lifenizer.DataModels;

namespace lifenizer.Converters
{
    public interface IConverter
    {
        /// <summary>
        /// Converts a file under a given path to a <see cref="Conversation"/>
        /// </summary>
        /// <param name="path">The path of the file to import</param>
        /// <returns>A <see cref="Conversation"/> with the relevant content of the file to import</returns>
        Conversation Convert(string path, params string[] options);

        IEnumerable<string> MimeTypes {get;}
    }
}

