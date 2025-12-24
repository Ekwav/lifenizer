/**
 * From https://stackoverflow.com/a/49115219
 * Falls under https://creativecommons.org/licenses/by-sa/3.0/
 */
import { HttpClient } from '@angular/common/http';
import { Pipe, PipeTransform } from '@angular/core';
import { Observable } from 'rxjs';


@Pipe({
  name: 'secure',
  standalone: false
})
export class SecurePipe implements PipeTransform {

  constructor(private http: HttpClient) { }

  transform(url: string) {

    return new Observable<string>((observer) => {
      // This is a tiny blank image
      observer.next('data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==');

      this.http.get(url, { responseType: 'blob' }).subscribe(response => {
        const reader = new FileReader();
        reader.readAsDataURL(response);
        reader.onloadend = function () {
          observer.next(reader.result as string);
        };
      });

      return { unsubscribe() { } };
    });
  }
}
