using System.Collections.Generic;
using lifenizer.Converters;
using lifenizer.DataModels;
using MimeTypes;
using System.Linq;

namespace lifenizer.Converters
{
    public class ConverterFactory
    {
        public static ConverterFactory Instance {get;set;}

        private Dictionary<string,IConverter> Converters = new Dictionary<string, IConverter>();

        static ConverterFactory()
        {
            Instance = new ConverterFactory();
        }

        public virtual Conversation ConvertFile(string tempPath, string converterId = null)
        {

            if(converterId !=null&& Converters.TryGetValue(converterId,out IConverter converter))
                return converter.Convert(tempPath);
           
            
            var extention = System.IO.Path.GetExtension(tempPath);
            if(Converters.TryGetValue(extention.TrimStart('.'), out converter))
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
    }

}