using System.Collections.Generic;
using lifenizer.Converters;
using lifenizer.DataModels;
using MimeTypes;
using System.Linq;
using System.Reflection;
using System;

namespace lifenizer.Converters
{
    public interface IConverterFactory
    {
        void AddConverter(IConverter converter, params string[] capable);
        Conversation ConvertFile(string tempPath, string converterId = null);
        void LoadFromAssemblies();
    }

    public class ConverterFactory : IConverterFactory
    {
        public static IConverterFactory Instance { get; set; }

        private Dictionary<string, IConverter> Converters = new Dictionary<string, IConverter>();

        static ConverterFactory()
        {
            Instance = new ConverterFactory();
        }

        public virtual Conversation ConvertFile(string tempPath, string converterId = null)
        {

            if (converterId != null && Converters.TryGetValue(converterId, out IConverter converter))
                return converter.Convert(tempPath);


            var extention = System.IO.Path.GetExtension(tempPath);
            if (Converters.TryGetValue(extention.TrimStart('.'), out converter))
                return converter.Convert(tempPath);


            throw new System.Exception($"No Converter found for the passed identifier '{converterId}' or fileextetnion '{extention}'");
        }

        /// <summary>
        /// Adds a Converter
        /// </summary>
        /// <param name="converter">The converter to add</param>
        /// <param name="capable">MimeTypes that his Converter is capeable of</param>
        public void AddConverter(IConverter converter, params string[] capable)
        {
            AddForTypes(converter, converter.MimeTypes);
            AddForTypes(converter, capable);
        }

        private void AddForTypes(IConverter converter, IEnumerable<string> capable)
        {
            foreach (var mimeType in capable)
            {
                Converters[mimeType] = converter;
            }
        }

        /// <summary>
        /// Loads all implementations of <see cref="IConverter"/>
        /// in the calling assembly
        /// </summary>
        public void LoadFromAssemblies()
        {
            LoadFromAssemblies(Assembly
                .GetCallingAssembly());
        }

        /// <summary>
        /// Loads all implementations of <see cref="IConverter"/> 
        /// from the given <see cref="Assembly"/>
        /// </summary>
        /// <param name="assembly">The <see cref="Assembly"/> to load 
        /// <see cref="IConverter"/> implementations from</param>
        public void LoadFromAssemblies(Assembly assembly )
        {
            var type = typeof(IConverter);
            var assemblies =  assembly
                .GetReferencedAssemblies()
                .Select(Assembly.Load);
            assemblies = assemblies.Append(assembly);


            var types = assemblies
                .SelectMany(x => x.DefinedTypes)
                .Where(p => type.IsAssignableFrom(p))
                .Where(p => p.IsClass).ToList();
            
            foreach (var item in types)
            {
                var converter = (IConverter)Activator.CreateInstance(item);
                AddConverter(converter);
            }
        }
    }
}